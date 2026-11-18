import SwiftUI
import AppKit

/// 搜索结果分类：全局搜索时先按类型归类，再进入对应列表。
enum SearchResultCategory: String, CaseIterable, Identifiable {
    case photos
    case albums
    case folders
    case people
    case places

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "图片"
        case .albums: return "相簿"
        case .folders: return "文件夹"
        case .people: return "人物"
        case .places: return "地点"
        }
    }

    var icon: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .albums: return "rectangle.stack"
        case .folders: return "folder"
        case .people: return "person.2"
        case .places: return "mappin.and.ellipse"
        }
    }
}

/// 相簿 / 文件夹的命中项。
private struct SearchAssetHit: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let count: Int?
    let cover: PhotoItem?
    let placeholder: AlbumPlaceholderStyle
    let action: () -> Void
}

/// 人物命中项。
private struct SearchPersonHit: Identifiable {
    let id: String
    let name: String
    let count: Int
    let isPet: Bool
    let avatarData: Data?
    let action: () -> Void
}

/// 全局搜索结果页：顶部按「图片 / 相簿 / 文件夹 / 人物 / 地点」分类，
/// 图片沿用原来的照片网格（分页、选择、查看器都不变），其余类型各自给出卡片列表。
struct SearchResultsPage<PhotoContent: View>: View {
    @EnvironmentObject private var store: LibraryStore

    let query: String
    @ViewBuilder var photoContent: () -> PhotoContent

    @State private var category: SearchResultCategory = .photos

    var body: some View {
        let buckets = makeBuckets()
        let photos = photoCount
        let available = availableCategories(buckets, photoCount: photos)

        VStack(spacing: 0) {
            if available.count > 1 {
                categoryBar(available, buckets: buckets, photoCount: photos)
            }

            if category == .photos || !available.contains(category) {
                photoContent()
            } else {
                categoryContent(category, buckets: buckets)
            }
        }
        .onAppear { selectDefaultIfNeeded(available) }
        .onChange(of: query) { _, _ in
            category = .photos
            selectDefaultIfNeeded(availableCategories(makeBuckets(), photoCount: photoCount))
        }
    }

    private var photoCount: Int { store.visibleCount }

    // MARK: - 分类条

    private func categoryBar(_ categories: [SearchResultCategory],
                             buckets: SearchBuckets,
                             photoCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { item in
                    let count = count(for: item, buckets: buckets, photoCount: photoCount)
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { category = item }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(count.formatted())
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(category == item ? Color.primary.opacity(0.7) : Color.secondary)
                        }
                        .foregroundStyle(category == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            if category == item {
                                Capsule()
                                    .fill(.regularMaterial)
                                    .overlay {
                                        Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
                                    }
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("只看\(item.title)")
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private func availableCategories(_ buckets: SearchBuckets,
                                     photoCount: Int) -> [SearchResultCategory] {
        var result: [SearchResultCategory] = [.photos]
        if buckets.albums.isEmpty == false { result.append(.albums) }
        if buckets.folders.isEmpty == false { result.append(.folders) }
        if buckets.people.isEmpty == false { result.append(.people) }
        if buckets.places.isEmpty == false { result.append(.places) }
        return result
    }

    private func count(for category: SearchResultCategory,
                       buckets: SearchBuckets,
                       photoCount: Int) -> Int {
        switch category {
        case .photos: return photoCount
        case .albums: return buckets.albums.count
        case .folders: return buckets.folders.count
        case .people: return buckets.people.count
        case .places: return buckets.places.count
        }
    }

    /// 没有图片命中但相簿 / 文件夹等命中时，直接把默认分类切到第一个有结果的类型，
    /// 否则用户会停在一个空的「图片」页上。
    private func selectDefaultIfNeeded(_ available: [SearchResultCategory]) {
        if category != .photos, !available.contains(category) {
            category = .photos
        }
        guard category == .photos, photoCount == 0 else { return }
        if let first = available.first(where: { $0 != .photos }) {
            category = first
        }
    }

    // MARK: - 分类内容

    @ViewBuilder
    private func categoryContent(_ category: SearchResultCategory, buckets: SearchBuckets) -> some View {
        ScrollView {
            Group {
                switch category {
                case .albums:
                    assetGrid(buckets.albums)
                case .folders:
                    assetGrid(buckets.folders)
                case .people:
                    peopleGrid(buckets.people)
                case .places:
                    placesGrid(buckets.places)
                case .photos:
                    EmptyView()
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 44)
        }
    }

    private func assetGrid(_ hits: [SearchAssetHit]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220),
                                     spacing: 18, alignment: .top)],
                  alignment: .leading,
                  spacing: 22) {
            ForEach(hits) { hit in
                SearchAssetCard(hit: hit)
            }
        }
    }

    private func peopleGrid(_ hits: [SearchPersonHit]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140),
                                     spacing: 16, alignment: .top)],
                  alignment: .leading,
                  spacing: 20) {
            ForEach(hits) { hit in
                SearchPersonCard(hit: hit)
            }
        }
    }

    private func placesGrid(_ clusters: [PlaceCluster]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420),
                                     spacing: 14, alignment: .top)],
                  alignment: .leading,
                  spacing: 14) {
            ForEach(clusters) { cluster in
                SearchPlaceRow(cluster: cluster)
            }
        }
    }

    // MARK: - 数据

    private struct SearchBuckets {
        var albums: [SearchAssetHit] = []
        var folders: [SearchAssetHit] = []
        var people: [SearchPersonHit] = []
        var places: [PlaceCluster] = []
    }

    private func makeBuckets() -> SearchBuckets {
        var buckets = SearchBuckets()
        // 网盘范围没有相簿 / 人物的分类概念，只保留图片结果。
        guard !store.isCloudScope else { return buckets }

        if store.isSystemScope {
            buckets.albums = store.systemAlbums
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { album in
                    SearchAssetHit(id: "system-album-\(album.id)",
                                   title: album.name,
                                   subtitle: systemFolderPath(album.parentFolder),
                                   count: store.systemAlbumPhotoCount(album.id),
                                   cover: store.systemAlbumPreviewPhotos(album.id, limit: 1).first,
                                   placeholder: .album,
                                   action: { store.navigate(to: .systemAlbum(album.id)) })
                }
            buckets.folders = store.systemFolders
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { folder in
                    SearchAssetHit(id: "system-folder-\(folder.id)",
                                   title: folder.name,
                                   subtitle: systemFolderPath(folder.parent),
                                   count: nil,
                                   cover: nil,
                                   placeholder: .folder,
                                   action: { store.navigate(to: .systemFolder(folder.id)) })
                }
            buckets.people = store.systemPeople
                .filter { !$0.isUnnamed && $0.name.localizedCaseInsensitiveContains(query) }
                .map { person in
                    SearchPersonHit(id: "system-person-\(person.id)",
                                    name: person.name,
                                    count: person.assetIDs.isEmpty ? person.faceCount : person.assetIDs.count,
                                    isPet: person.isPet,
                                    avatarData: person.cropData,
                                    action: {
                                        store.navigate(to: .systemPeople)
                                        store.openPerson(person)
                                    })
                }
        } else {
            buckets.albums = store.albums
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { album in
                    SearchAssetHit(id: "album-\(album.id.uuidString)",
                                   title: album.name,
                                   subtitle: store.folderPath(album.folderID),
                                   count: album.photoIDs.count,
                                   cover: (album.coverPhotoID ?? album.photoIDs.first).flatMap { store.anyPhoto(id: $0) },
                                   placeholder: .album,
                                   action: { store.navigate(to: .album(album.id)) })
                }
            buckets.folders = store.folders
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { folder in
                    SearchAssetHit(id: "folder-\(folder.id.uuidString)",
                                   title: folder.name,
                                   subtitle: store.folderPath(folder.parentID),
                                   count: nil,
                                   cover: nil,
                                   placeholder: .folder,
                                   action: { store.navigate(to: .folder(folder.id)) })
                }
            buckets.people = store.localPeople
                .filter { !$0.isUnnamed && $0.name.localizedCaseInsensitiveContains(query) }
                .map { person in
                    SearchPersonHit(id: "person-\(person.id.uuidString)",
                                    name: person.name,
                                    count: person.assetIDs.count,
                                    isPet: false,
                                    avatarData: person.coverImageData,
                                    action: {
                                        store.navigate(to: .people)
                                        store.selectedLocalPersonID = person.id
                                    })
                }
        }

        buckets.places = placeMatches()
        return buckets
    }

    /// 地点命中：系统图库索引模式下，聚类需要先读全量带定位照片。
    /// 地图 / 地点页已经算过时直接复用缓存；还没算过就先不参与搜索，
    /// 避免用户每敲一个字都同步扫一遍整库。
    private func placeMatches() -> [PlaceCluster] {
        if store.isSystemScope, store.systemIndex != nil,
           store.placeClustersCacheKey != store.contentRevision {
            return []
        }
        return store.placeClusters.filter { cluster in
            cluster.title.localizedCaseInsensitiveContains(query)
                || (cluster.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
                || cluster.group.localizedCaseInsensitiveContains(query)
        }
    }

    /// 系统图库的文件夹路径：沿 `parent` 向上拼，最多 8 层防止异常数据成环。
    private func systemFolderPath(_ id: Int64?) -> String {
        var parts: [String] = []
        var current = id
        var depth = 0
        while let folderID = current, depth < 8,
              let folder = store.systemFolders.first(where: { $0.id == folderID }) {
            parts.insert(folder.name, at: 0)
            current = folder.parent
            depth += 1
        }
        return parts.joined(separator: " / ")
    }
}

// MARK: - 结果卡片

/// 相簿 / 文件夹卡片：悬停状态放在卡片内部，避免鼠标移动触发整页重算。
private struct SearchAssetCard: View {
    @EnvironmentObject private var settings: AppSettings

    let hit: SearchAssetHit
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: hit.cover, side: 220, style: hit.placeholder)
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                                      lineWidth: hovering ? 1 : 0.5)
                }
                .shadow(color: .black.opacity(hovering ? 0.20 : 0.05), radius: 12, y: 5)
                .scaleEffect(hovering && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hovering)

            HStack(spacing: 5) {
                Text(hit.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count = hit.count {
                    Text(count.formatted())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 2)

            if !hit.subtitle.isEmpty {
                Text(hit.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: hit.action)
        .help(hit.subtitle.isEmpty ? hit.title : "\(hit.title) · \(hit.subtitle)")
    }
}

private struct SearchPersonCard: View {
    @EnvironmentObject private var settings: AppSettings

    let hit: SearchPersonHit
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.55),
                                                  Color.accentColor.opacity(0.22)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let data = hit.avatarData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: hit.isPet ? "pawprint.fill" : "person.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 78, height: 78)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.18),
                                      lineWidth: hovering ? 1.6 : 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: 10, y: 4)
            .scaleEffect(hovering && settings.hoverLift ? settings.motion.hoverScale : 1)
            .animation(settings.motion.hover, value: hovering)

            Text(hit.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text("\(hit.count.formatted()) 张")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: hit.action)
        .help(hit.name)
    }
}

private struct SearchPlaceRow: View {
    @EnvironmentObject private var store: LibraryStore

    let cluster: PlaceCluster
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(cluster.subtitle ?? cluster.group)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(cluster.count.formatted()) 张")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.075 : 0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.07),
                              lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture {
            store.navigate(to: store.isSystemScope ? .systemPlaces : .places)
            store.openPlace(cluster)
        }
        .help("查看 \(cluster.title) 的影像足迹")
    }
}
