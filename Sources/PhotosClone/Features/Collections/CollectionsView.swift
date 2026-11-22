import AppKit
import SwiftUI

struct PhotoMosaicView: View {
    let photos: [PhotoItem]
    var count: Int = 4

    var body: some View {
        GeometryReader { geo in
            let visibleCount = photos.isEmpty ? count : min(count, photos.count)
            let spacing: CGFloat = 2
            let cellWidth = max(1, (geo.size.width - spacing * CGFloat(visibleCount - 1)) / CGFloat(visibleCount))
            HStack(spacing: spacing) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    Group {
                        if index < photos.count {
                            PhotoThumbnailView(photo: photos[index])
                        } else {
                            // 缺图占位用语义色，浅色下不会出现深灰黑块。
                            Color.primary.opacity(0.06)
                        }
                    }
                    .frame(width: cellWidth, height: geo.size.height)
                }
            }
        }
    }
}

struct SmartCollectionCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let photos: [PhotoItem]
    var tint: Color = .accentColor
    let action: () -> Void
}

struct CollectionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredID: String?

    private var cards: [SmartCollectionCard] {
        let revisit = store.revisitPhotos
        return [
            SmartCollectionCard(id: "favorites", title: "个人收藏", subtitle: "\(store.photos(for: .favorites).count) 项",
                                icon: "heart.fill", photos: Array(store.photos(for: .favorites).prefix(4)), tint: .pink) {
                store.navigate(to: .favorites)
            },
            SmartCollectionCard(id: "revisit", title: "值得重看", subtitle: "\(revisit.count) 项旧照片",
                                icon: "clock.arrow.circlepath", photos: Array(revisit.prefix(4)), tint: .mint) {
                store.navigate(to: .revisit)
            },
            SmartCollectionCard(id: "recent", title: "最近保存", subtitle: "\(store.photos(for: .recentlySaved).count) 项",
                                icon: "square.and.arrow.down", photos: Array(store.photos(for: .recentlySaved).prefix(4)), tint: .blue) {
                store.navigate(to: .recentlySaved)
            },
            SmartCollectionCard(id: "videos", title: "视频", subtitle: "\(store.photos(for: .videos).count) 个",
                                icon: "video.fill", photos: Array(store.photos(for: .videos).prefix(4)), tint: .purple) {
                store.navigate(to: .videos)
            },
            SmartCollectionCard(id: "screenshots", title: "截屏", subtitle: "\(store.photos(for: .screenshots).count) 项",
                                icon: "camera.viewfinder", photos: Array(store.photos(for: .screenshots).prefix(4)), tint: .teal) {
                store.navigate(to: .screenshots)
            },
            SmartCollectionCard(id: "selfies", title: "自拍", subtitle: "\(store.photos(for: .selfies).count) 项",
                                icon: "person.crop.square", photos: Array(store.photos(for: .selfies).prefix(4)), tint: .orange) {
                store.navigate(to: .selfies)
            },
            SmartCollectionCard(id: "panoramas", title: "全景照片", subtitle: "\(store.photos(for: .panoramas).count) 项",
                                icon: "pano", photos: Array(store.photos(for: .panoramas).prefix(4)), tint: .indigo) {
                store.navigate(to: .panoramas)
            },
            SmartCollectionCard(id: "edited", title: "已编辑", subtitle: "\(store.photos.filter { $0.hasEdits }.count) 项",
                                icon: "slider.horizontal.3", photos: Array(store.photos.filter { $0.hasEdits }.prefix(4)), tint: .gray) {
                store.navigate(to: .library)
                store.photoFilter = .edited
            },
            SmartCollectionCard(id: "loose", title: "不在相簿中", subtitle: "\(loosePhotos.count) 项",
                                icon: "rectangle.stack.badge.minus", photos: Array(loosePhotos.prefix(4)), tint: .brown) {
                store.navigate(to: .library)
                store.photoFilter = .notInAlbum
            }
        ]
    }

    private var loosePhotos: [PhotoItem] {
        let ids = Set(store.albums.flatMap { $0.photoIDs })
        return store.photos.filter { $0.deletedAt == nil && !$0.isHidden && !ids.contains($0.id) }
    }

    /// 置顶的「那年今日」，取最近的一年。
    private var throwbackHero: PhotoMemory? {
        store.memories.first { $0.kind == .throwback }
    }

    private var memoriesToShow: [PhotoMemory] {
        store.memories.filter { $0.id != throwbackHero?.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let hero = throwbackHero {
                    throwbackBanner(hero)
                }

                if !memoriesToShow.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("回忆")
                                .font(.system(size: 17, weight: .semibold))
                            Text("自动生成的影片")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(memoriesToShow) { memory in
                                    memoryCard(memory)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !store.trips.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("旅行")
                                .font(.system(size: 17, weight: .semibold))
                            Text("按时间与地点自动串联")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(store.trips) { trip in
                                    tripCard(trip)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 380), spacing: 16)], spacing: 16) {
                    ForEach(cards) { card in
                        collectionCard(card)
                            .onTapGesture { card.action() }
                            .onHover { hovering in
                                hoveredID = hovering ? card.id : (hoveredID == card.id ? nil : hoveredID)
                            }
                    }
                }
            }
            .padding(24)
        }
    }

    private func throwbackBanner(_ memory: PhotoMemory) -> some View {
        Button {
            store.activeMemory = memory
        } label: {
            ZStack(alignment: .bottomLeading) {
                PhotoMosaicView(photos: Array(memory.photos.prefix(4)))
                LinearGradient(colors: [.clear, .black.opacity(0.82)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                        Text("那年今日")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())

                    Text(memory.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(memory.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(18)

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    Spacer()
                }
                .padding(16)
            }
            .frame(height: 216)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("播放那年今日")
    }

    private func tripCard(_ trip: TripStory) -> some View {
        Button {
            store.activeTrip = trip
        } label: {
            ZStack(alignment: .bottomLeading) {
                PhotoMosaicView(photos: Array(trip.photos.prefix(4)))
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(trip.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .padding(12)

                VStack {
                    HStack {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.3), in: Circle())
                            .background(.ultraThinMaterial, in: Circle())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 258, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("查看旅行故事线")
    }

    private func memoryCard(_ memory: PhotoMemory) -> some View {
        Button {
            store.activeMemory = memory
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let first = memory.photos.first {
                    PhotoThumbnailView(photo: first)
                } else {
                    LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.2)],
                                   startPoint: .top, endPoint: .bottom)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.78)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(memory.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(memory.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(12)

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 178, height: 224)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("播放回忆影片")
    }

    private func collectionCard(_ card: SmartCollectionCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            if card.photos.isEmpty {
                LinearGradient(colors: [card.tint.opacity(0.55), card.tint.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: card.icon)
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.primary.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoMosaicView(photos: card.photos)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(card.subtitle)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(14)

            VStack {
                HStack {
                    Image(systemName: card.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.28), in: Circle())
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle().strokeBorder(card.tint.opacity(0.55), lineWidth: 0.8)
                        }
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(height: 186)
        .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: settings.cardRadius)
                .strokeBorder(Color.white.opacity(hoveredID == card.id ? 0.35 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(hoveredID == card.id ? 0.24 : 0.18),
                radius: hoveredID == card.id ? 14 : 10, y: hoveredID == card.id ? 6 : 4)
        .scaleEffect(hoveredID == card.id && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hoveredID)
        .contentShape(RoundedRectangle(cornerRadius: settings.cardRadius))
    }
}

struct AlbumsOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// 非空时只展示该文件夹下的子文件夹与相簿（点侧边栏文件夹进入时使用）。
    var folderID: UUID? = nil
    @State private var namePrompt: NamePromptPayload?
    @State private var hoveredKey: String?
    @State private var dropTargetAlbumID: UUID?

    /// 卡片墙每行列数：默认尺寸下 5 个，随工具栏缩放变化。
    var body: some View {
        GeometryReader { proxy in
            let liveByID = livePhotoIndex
            let childFolders = visibleFolders
            let childAlbums = visibleAlbums
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if childFolders.isEmpty && childAlbums.isEmpty {
                        emptyState
                    } else if store.albumDisplayStyle == .grid {
                        let folderPhotos = folderPhotosMap(childFolders, liveByID: liveByID)
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(childFolders) { folder in
                                folderCard(folder, width: itemWidth,
                                           photos: folderPhotos[folder.id] ?? [])
                            }
                            ForEach(childAlbums) { album in
                                albumCard(album, width: itemWidth,
                                          photo: albumCover(album, liveByID: liveByID))
                            }
                        }
                    } else if store.albumDisplayStyle == .list {
                        listLayout(childFolders: childFolders,
                                   childAlbums: childAlbums,
                                   folderPhotos: folderPhotosMap(childFolders, liveByID: liveByID),
                                   liveByID: liveByID,
                                   width: proxy.size.width)
                    } else {
                        collageLayout(childFolders: childFolders,
                                      childAlbums: childAlbums,
                                      folderPhotos: folderPhotosMap(childFolders, liveByID: liveByID),
                                      liveByID: liveByID)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(settings.motion.layout, value: store.albumDisplayStyle)
        .sheet(item: $namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 页面标题与返回层级已由窗口工具栏统一展示，这里只保留数量与操作。
            Text("\(visibleAlbums.count) 个相簿, \(visibleFolders.count) 个文件夹")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            displayStyleMenu
            Menu {
                Button("新建相簿") { namePrompt = .newAlbum(folderID: folderID) }
                Button("新建文件夹") { namePrompt = .newFolder(parentID: folderID) }
            } label: {
                Label("新建", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var displayStyleMenu: some View {
        AlbumDisplayStyleMenu()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(folderID == nil ? "还没有相簿" : "这个文件夹是空的")
                .font(.system(size: 17, weight: .semibold))
            Text(folderID == nil
                 ? "新建相簿，或导入文件夹时自动按目录创建。"
                 : "可以在这个文件夹里新建相簿或子文件夹。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("新建相簿") { namePrompt = .newAlbum(folderID: folderID) }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    /// 只展示当前层级的子文件夹：顶层的「所有相簿」是第 1 层，进入文件夹后逐层向下。
    private var visibleFolders: [AlbumFolder] {
        store.childFolders(of: folderID)
    }

    /// 只展示当前层级的直接相簿（顶层即未归入任何文件夹的相簿）。
    private var visibleAlbums: [Album] {
        store.albums(in: folderID)
    }

    private var livePhotoIndex: [UUID: PhotoItem] {
        Dictionary(store.photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.map { ($0.id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// 相簿封面：用户指定优先，否则取相簿内第一张（照片或视频缩略图）。
    private func albumCover(_ album: Album, liveByID: [UUID: PhotoItem]) -> PhotoItem? {
        if let coverID = album.coverPhotoID,
           album.photoIDs.contains(coverID),
           let cover = liveByID[coverID] {
            return cover
        }
        for id in album.photoIDs {
            if let photo = liveByID[id] { return photo }
        }
        return nil
    }

    /// 文件夹封面：从子树的相簿里取最多 4 张，用于四宫格缩略图。
    private func folderPhotosMap(_ folders: [AlbumFolder],
                                 liveByID: [UUID: PhotoItem]) -> [UUID: [PhotoItem]] {
        var result: [UUID: [PhotoItem]] = [:]
        for folder in folders {
            let folderIDs = store.folderSubtreeIDs(folder.id)
            var photos: [PhotoItem] = []
            for album in store.albums where album.folderID.map({ folderIDs.contains($0) }) ?? false {
                for photo in albumPhotos(album, liveByID: liveByID, limit: 4) where photos.count < 4 {
                    if !photos.contains(where: { $0.id == photo.id }) { photos.append(photo) }
                }
                if photos.count >= 4 { break }
            }
            result[folder.id] = photos
        }
        return result
    }

    // MARK: - 列表 / 拼贴墙

    /// 相簿封面照片：用户指定封面优先，最多取 4 张用于列表与拼贴墙的拼贴。
    private func albumPhotos(_ album: Album,
                             liveByID: [UUID: PhotoItem],
                             limit: Int = 4) -> [PhotoItem] {
        var result: [PhotoItem] = []
        if let coverID = album.coverPhotoID, let cover = liveByID[coverID] {
            result.append(cover)
        }
        for id in album.photoIDs where result.count < limit {
            if id == album.coverPhotoID { continue }
            if let photo = liveByID[id] { result.append(photo) }
        }
        return result
    }

    private func albumPhotoCount(_ album: Album, liveByID: [UUID: PhotoItem]) -> Int {
        album.photoIDs.reduce(0) { total, id in total + (liveByID[id] == nil ? 0 : 1) }
    }

    private func folderAlbumCount(_ folder: AlbumFolder) -> Int {
        let ids = store.folderSubtreeIDs(folder.id)
        return store.albums.reduce(0) { total, album in
            guard let folderID = album.folderID, ids.contains(folderID) else { return total }
            return total + 1
        }
    }

    private func listLayout(childFolders: [AlbumFolder],
                            childAlbums: [Album],
                            folderPhotos: [UUID: [PhotoItem]],
                            liveByID: [UUID: PhotoItem],
                            width: CGFloat) -> some View {
        let spacing: CGFloat = 28
        let available = max(240, width - 48)
        let columns = max(1, min(6, Int((available + spacing) / (300 + spacing))))
        let itemWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let thumb = min(160, max(64, CGFloat(store.thumbSize) * 0.75))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth),
                                                            spacing: spacing,
                                                            alignment: .leading),
                                       count: columns),
                         alignment: .leading,
                         spacing: 24) {
            ForEach(childFolders) { folder in
                folderListRow(folder, photo: folderPhotos[folder.id]?.first, thumb: thumb)
            }
            ForEach(childAlbums) { album in
                albumListRow(album,
                             cover: albumCover(album, liveByID: liveByID),
                             liveByID: liveByID,
                             thumb: thumb)
            }
        }
    }

    private func collageLayout(childFolders: [AlbumFolder],
                               childAlbums: [Album],
                               folderPhotos: [UUID: [PhotoItem]],
                               liveByID: [UUID: PhotoItem]) -> some View {
        // 拼贴墙的方块跟随工具栏缩放（56…360 → 120…320）。
        let tile = min(320, max(120, CGFloat(store.thumbSize) * 1.7))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile),
                                            spacing: 10, alignment: .top)],
                         alignment: .leading,
                         spacing: 10) {
            ForEach(childFolders) { folder in
                folderCollageTile(folder, photos: folderPhotos[folder.id] ?? [], side: tile)
            }
            ForEach(childAlbums) { album in
                albumCollageTile(album,
                                 photos: albumPhotos(album, liveByID: liveByID),
                                 liveByID: liveByID,
                                 side: tile)
            }
        }
    }

    private func folderListRow(_ folder: AlbumFolder, photo: PhotoItem?, thumb: CGFloat) -> some View {
        AlbumOverviewRow(title: folder.name,
                         subtitle: folderAlbumCount(folder).formatted(),
                         cover: photo,
                         placeholder: .folder,
                         side: thumb,
                         action: { store.navigate(to: .folder(folder.id)) },
                         menu: { folderMenuItems(folder) })
            .accessibilityLabel("文件夹 \(folder.name)")
    }

    private func albumListRow(_ album: Album,
                              cover: PhotoItem?,
                              liveByID: [UUID: PhotoItem],
                              thumb: CGFloat) -> some View {
        let count = albumPhotoCount(album, liveByID: liveByID)
        return AlbumOverviewRow(title: album.name,
                                subtitle: count.formatted(),
                                cover: cover,
                                placeholder: .album,
                                side: thumb,
                                highlighted: dropTargetAlbumID == album.id,
                                action: { store.navigate(to: .album(album.id)) },
                                menu: { albumMenuItems(album) })
            .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty else { return }
                    store.addToAlbum(album.id, photoIDs: Set(ids))
                }
                return true
            }
            .accessibilityLabel("相簿 \(album.name)")
    }

    private func folderCollageTile(_ folder: AlbumFolder, photos: [PhotoItem], side: CGFloat) -> some View {
        AlbumOverviewTile(title: folder.name,
                          subtitle: "\(folderAlbumCount(folder)) 个相簿",
                          photos: photos,
                          placeholder: .folder,
                          side: side,
                          isFolder: true,
                          action: { store.navigate(to: .folder(folder.id)) },
                          menu: { folderMenuItems(folder) })
            .accessibilityLabel("文件夹 \(folder.name)")
    }

    private func albumCollageTile(_ album: Album,
                                  photos: [PhotoItem],
                                  liveByID: [UUID: PhotoItem],
                                  side: CGFloat) -> some View {
        let count = albumPhotoCount(album, liveByID: liveByID)
        return AlbumOverviewTile(title: album.name,
                                 subtitle: "\(count) 项",
                                 photos: photos,
                                 placeholder: .album,
                                 side: side,
                                 isFolder: false,
                                 highlighted: dropTargetAlbumID == album.id,
                                 action: { store.navigate(to: .album(album.id)) },
                                 menu: { albumMenuItems(album) })
            .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty else { return }
                    store.addToAlbum(album.id, photoIDs: Set(ids))
                }
                return true
            }
            .accessibilityLabel("相簿 \(album.name)")
    }

    private func albumDropBinding(_ album: Album) -> Binding<Bool> {
        Binding(
            get: { dropTargetAlbumID == album.id },
            set: { targeted in
                if targeted {
                    dropTargetAlbumID = album.id
                } else if dropTargetAlbumID == album.id {
                    dropTargetAlbumID = nil
                }
            }
        )
    }

    // MARK: - 卡片

    private func folderCard(_ folder: AlbumFolder, width: CGFloat, photos: [PhotoItem]) -> some View {
        let key = "folder-\(folder.id.uuidString)"
        return VStack(alignment: .leading, spacing: 8) {
            FolderMosaicImage(photos: photos, side: width)
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            caption(folder.name, subtitle: "")
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: .folder(folder.id))
        }
        .contextMenu {
            folderMenuItems(folder)
        }
        .accessibilityLabel("文件夹 \(folder.name)")
    }

    /// 文件夹卡片的右键菜单：网格 / 列表 / 拼贴墙共用。
    @ViewBuilder
    private func folderMenuItems(_ folder: AlbumFolder) -> some View {
        Button("打开文件夹") { store.navigate(to: .folder(folder.id)) }
        Divider()
        Button("新建相簿…") { namePrompt = .newAlbum(folderID: folder.id) }
        Button("新建子文件夹…") { namePrompt = .newFolder(parentID: folder.id) }
        Divider()
        Button("重命名文件夹…") { namePrompt = .renameFolder(folder.id, current: folder.name) }
        Button("删除文件夹", role: .destructive) { store.deleteFolder(folder.id) }
    }

    /// 相簿卡片的右键菜单：网格 / 列表 / 拼贴墙共用。
    @ViewBuilder
    private func albumMenuItems(_ album: Album) -> some View {
        Button("打开相簿") { store.navigate(to: .album(album.id)) }
        Button("重命名相簿…") {
            namePrompt = .renameAlbum(album.id, current: album.name)
        }
        Menu("移到文件夹") {
            Button("相簿顶层") { store.moveAlbum(album.id, toFolder: nil) }
            if !store.folderOptions.isEmpty { Divider() }
            ForEach(store.folderOptions) { option in
                Button(option.path) { store.moveAlbum(album.id, toFolder: option.id) }
            }
        }
        if album.coverPhotoID != nil {
            Divider()
            Button("恢复自动封面") { store.setAlbumCover(nil, for: album.id) }
        }
        Divider()
        Button("删除相簿", role: .destructive) { store.deleteAlbum(album.id) }
    }

    private func albumCard(_ album: Album, width: CGFloat, photo: PhotoItem?) -> some View {
        let key = "album-\(album.id.uuidString)"
        let path = album.folderID.map { store.folderPath($0) } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: photo, side: width)
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(dropTargetAlbumID == album.id ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: dropTargetAlbumID == album.id ? 2 : 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            caption(album.name, subtitle: path)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onDrop(of: [.plainText], isTargeted: albumDropBinding(album)) { providers in
            PhotoDrag.loadIDs(from: providers) { ids in
                guard !ids.isEmpty else { return }
                store.addToAlbum(album.id, photoIDs: Set(ids))
            }
            return true
        }
        .onTapGesture {
            store.navigate(to: .album(album.id))
        }
        .contextMenu {
            albumMenuItems(album)
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    private func caption(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// 官方「照片」图库里的文件夹：只展示下一层的子文件夹与相簿（与系统「照片」一致），只读。
struct SystemFolderOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// 为空时展示系统图库根层（「相簿」分区总览）。
    var folderID: Int64? = nil

    @State private var hoveredKey: String?

    /// 卡片墙每行列数：默认尺寸下 5 个，与「所有相簿」一致。
    private var entries: [SystemSidebarEntry] {
        if let folderID { return store.systemChildren(of: folderID) }
        return store.systemChildren(of: nil)
    }

    private var childFolders: [SystemFolderInfo] {
        entries.compactMap { entry in
            if case .folder(let folder) = entry { return folder }
            return nil
        }
    }

    private var childAlbums: [SystemAlbumInfo] {
        entries.compactMap { entry in
            if case .album(let album) = entry { return album }
            return nil
        }
    }

    private var folder: SystemFolderInfo? {
        guard let folderID else { return nil }
        return store.systemFolders.first(where: { $0.id == folderID })
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if entries.isEmpty {
                        emptyState
                    } else if store.albumDisplayStyle == .grid {
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            // 按侧边栏的原始顺序混排文件夹与相簿，保证两个入口看到的排序一致。
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderCard(child, width: itemWidth)
                                case .album(let album):
                                    albumCard(album, width: itemWidth)
                                }
                            }
                        }
                    } else if store.albumDisplayStyle == .list {
                        let spacing: CGFloat = 28
                        let available = max(240, proxy.size.width - 48)
                        let columns = max(1, min(6, Int((available + spacing) / (300 + spacing))))
                        let itemWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                        let thumb = min(160, max(64, CGFloat(store.thumbSize) * 0.75))
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth),
                                                                     spacing: spacing,
                                                                     alignment: .leading),
                                                 count: columns),
                                  alignment: .leading,
                                  spacing: 24) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderListRow(child, thumb: thumb)
                                case .album(let album):
                                    albumListRow(album, thumb: thumb)
                                }
                            }
                        }
                    } else {
                        let tile = min(320, max(120, CGFloat(store.thumbSize) * 1.7))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile),
                                                     spacing: 10, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 10) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderCollageTile(child, side: tile)
                                case .album(let album):
                                    albumCollageTile(album, side: tile)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(settings.motion.layout, value: store.albumDisplayStyle)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 标题与返回层级由窗口工具栏统一展示，这里只保留数量与显示方式。
            Text("\(childAlbums.count) 个相簿, \(childFolders.count) 个文件夹")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            AlbumDisplayStyleMenu()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(folderID == nil ? "还没有相簿" : "这个文件夹是空的")
                .font(.system(size: 17, weight: .semibold))
            Text(folderID == nil
                 ? "系统「照片」里还没有相簿或文件夹。"
                 : "系统「照片」里还没有在这个文件夹下添加相簿。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - 封面

    /// 文件夹的四宫格封面（异步）：从自身与更深层相簿里取最多 4 张；限制递归深度。
    /// 相簿墙可能有上万个相簿，封面查询必须离开 body 主线程，否则打开文件夹就卡住。
    private func folderPhotosAsync(_ id: Int64, limit: Int = 4, depth: Int = 0) async -> [PhotoItem] {
        guard limit > 0, depth < 4 else { return [] }
        var result: [PhotoItem] = []
        for entry in store.systemChildren(of: id) {
            guard result.count < limit else { break }
            let photos: [PhotoItem]
            switch entry {
            case .album(let album):
                photos = await store.systemAlbumPreviewPhotosAsync(album.id, limit: limit)
            case .folder(let child):
                photos = await folderPhotosAsync(child.id, limit: limit, depth: depth + 1)
            }
            for photo in photos where result.count < limit {
                if !result.contains(where: { $0.id == photo.id }) { result.append(photo) }
            }
        }
        return result
    }

    // MARK: - 卡片

    private func folderCard(_ child: SystemFolderInfo, width: CGFloat) -> some View {
        let key = "folder-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id)
        } content: { photos in
            cardBody(key: key,
                     title: child.name,
                     cover: photos.first,
                     photos: photos,
                     placeholder: .folder,
                     width: width) {
                store.navigate(to: .systemFolder(child.id))
            } contextMenu: {
                Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
            }
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    private func albumCard(_ album: SystemAlbumInfo, width: CGFloat) -> some View {
        let key = "album-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 1)
        } content: { photos in
            cardBody(key: key,
                     title: album.name,
                     cover: photos.first,
                     placeholder: .album,
                     width: width) {
                store.navigate(to: .systemAlbum(album.id))
            } contextMenu: {
                Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
            }
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    // MARK: - 列表 / 拼贴墙

    /// 文件夹子树里的相簿数量（限制递归深度，避免异常结构）。
    private func folderAlbumCount(_ id: Int64, depth: Int = 0) -> Int {
        guard depth < 4 else { return 0 }
        return store.systemChildren(of: id).reduce(0) { total, entry in
            switch entry {
            case .album:
                return total + 1
            case .folder(let child):
                return total + folderAlbumCount(child.id, depth: depth + 1)
            }
        }
    }

    private func folderListRow(_ child: SystemFolderInfo, thumb: CGFloat) -> some View {
        let key = "folder-row-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id, limit: 1)
        } content: { photos in
            AlbumOverviewRow(title: child.name,
                             subtitle: folderAlbumCount(child.id).formatted(),
                             cover: photos.first,
                             placeholder: .folder,
                             side: thumb,
                             action: { store.navigate(to: .systemFolder(child.id)) },
                             menu: {
                                 Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                                 Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
                             })
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    private func albumListRow(_ album: SystemAlbumInfo, thumb: CGFloat) -> some View {
        let key = "album-row-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 1)
        } content: { photos in
            AlbumOverviewRow(title: album.name,
                             subtitle: store.systemAlbumPhotoCount(album.id).formatted(),
                             cover: photos.first,
                             placeholder: .album,
                             side: thumb,
                             action: { store.navigate(to: .systemAlbum(album.id)) },
                             menu: {
                                 Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                                 Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
                             })
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    private func folderCollageTile(_ child: SystemFolderInfo, side: CGFloat) -> some View {
        let key = "folder-tile-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id)
        } content: { photos in
            AlbumOverviewTile(title: child.name,
                              subtitle: "\(folderAlbumCount(child.id)) 个相簿",
                              photos: photos,
                              placeholder: .folder,
                              side: side,
                              isFolder: true,
                              action: { store.navigate(to: .systemFolder(child.id)) },
                              menu: {
                                  Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                                  Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
                              })
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    private func albumCollageTile(_ album: SystemAlbumInfo, side: CGFloat) -> some View {
        let key = "album-tile-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 4)
        } content: { photos in
            AlbumOverviewTile(title: album.name,
                              subtitle: "\(store.systemAlbumPhotoCount(album.id)) 项",
                              photos: photos,
                              placeholder: .album,
                              side: side,
                              isFolder: false,
                              action: { store.navigate(to: .systemAlbum(album.id)) },
                              menu: {
                                  Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                                  Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
                              })
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    private func cardBody<MenuContent: View>(key: String,
                                             title: String,
                                             cover: PhotoItem?,
                                             photos: [PhotoItem] = [],
                                             placeholder: AlbumPlaceholderStyle,
                                             width: CGFloat,
                                             action: @escaping () -> Void,
                                             @ViewBuilder contextMenu: () -> MenuContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if photos.count >= 2 {
                    FolderMosaicImage(photos: photos, side: width)
                } else {
                    AlbumCoverImage(photo: cover, side: width, style: placeholder)
                }
            }
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture(perform: action)
        .contextMenu(menuItems: contextMenu)
    }
}

/// 封面异步加载器：先渲染占位，后台取到封面后再替换。
/// 相簿墙可能有上万个相簿，如果在 body 里同步查 `Photos.sqlite`，打开文件夹就会卡住。
private struct SystemCoverLoader<Content: View>: View {
    let key: String
    let load: () async -> [PhotoItem]
    private let content: ([PhotoItem]) -> Content

    @State private var photos: [PhotoItem] = []

    init(key: String,
         load: @escaping () async -> [PhotoItem],
         @ViewBuilder content: @escaping ([PhotoItem]) -> Content) {
        self.key = key
        self.load = load
        self.content = content
    }

    var body: some View {
        content(photos)
            .task(id: key) {
                let loaded = await load()
                guard !Task.isCancelled else { return }
                photos = loaded
            }
    }
}

/// 媒体类型总览：卡片墙展示各分类的数量与封面（侧边栏「媒体类型」分区头点开）。
struct MediaTypesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.mediaTypeSummary
        let system = store.isSystemScope
        let keys = (system ? MediaTypeKey.allCases : MediaTypeKey.localCases)
            .filter { (summary.counts[$0] ?? 0) > 0 }
        CategoryOverviewView(
            entries: keys.map { key in
                CategoryOverviewEntry(id: key.rawValue,
                                      title: key.title,
                                      icon: key.icon,
                                      count: summary.counts[key] ?? 0,
                                      cover: summary.covers[key],
                                      item: key.item(system: system))
            },
            emptyIcon: "square.grid.2x2",
            emptyTitle: "还没有媒体类型",
            emptyMessage: system
                ? "系统「照片」图库里还没有可分类的项目。"
                : "导入照片后会自动按类型归类。"
        )
    }
}

/// 场景总览：卡片墙展示端侧识别出的场景分类（本地图库用落库结果，系统图库用内存结果）。
struct ScenesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.sceneSummary
        let categories = SceneCatalog.categories.filter { (summary.counts[$0.id] ?? 0) > 0 }
        let system = store.isSystemScope
        let analyzed = system ? store.systemAnalyzedCount : store.analyzedCount
        let analyzing = system ? store.isAnalyzingSystemContent : store.isAnalyzingIntelligence
        CategoryOverviewView(
            entries: categories.map { category in
                CategoryOverviewEntry(id: category.id,
                                      title: category.title,
                                      icon: category.icon,
                                      count: summary.counts[category.id] ?? 0,
                                      cover: summary.covers[category.id],
                                      item: system ? .systemScene(category.id) : .scene(category.id))
            },
            emptyIcon: "sparkles",
            emptyTitle: analyzed == 0 ? "还没有识别照片内容" : "未识别到常见场景",
            emptyMessage: "识别场景与照片中的文字，全部在本机完成。",
            emptyActionTitle: analyzing ? nil : (system ? "识别照片内容…" : "分析照片内容…"),
            emptyAction: {
                if system {
                    store.analyzeSystemContent()
                } else {
                    store.analyzeIntelligence()
                }
            }
        )
    }
}

/// 分类总览里的一个卡片条目。
private struct CategoryOverviewEntry: Identifiable {
    let id: String
    let title: String
    let icon: String
    let count: Int
    let cover: PhotoItem?
    let item: SidebarItem
}

/// 分类卡片墙：媒体类型与场景共用（数量、封面均由 Store 汇总好）。
private struct CategoryOverviewView: View {
    let entries: [CategoryOverviewEntry]
    let emptyIcon: String
    let emptyTitle: String
    let emptyMessage: String
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredKey: String?

    /// 卡片墙每行列数：默认尺寸下 5 个，随工具栏缩放变化。
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 标题由窗口工具栏统一展示，这里只保留分类数量。
                    Text("\(entries.count) 个分类")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if entries.isEmpty {
                        emptyState
                    } else {
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(entries) { entry in
                                card(entry, width: itemWidth)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let emptyActionTitle, let emptyAction {
                Button(emptyActionTitle, action: emptyAction)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func card(_ entry: CategoryOverviewEntry, width: CGFloat) -> some View {
        let key = entry.id
        return VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: entry.cover, side: width, style: .icon(entry.icon))
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            HStack(spacing: 5) {
                Image(systemName: entry.icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.count.formatted())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: entry.item)
        }
        .accessibilityLabel("\(entry.title)，\(entry.count) 项")
    }
}

/// 更多项目总览：把侧边栏「更多项目」里的入口做成卡片列表（本地 / 系统图库共用）。
struct MoreItemsOverviewView: View {
    var system: Bool

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredKey: String?

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let icon: String
        let item: SidebarItem
    }

    private var entries: [Entry] {
        if system {
            // 与侧边栏「更多项目」同一顺序、同名、同图标；条件入口也与侧边栏一致。
            var list: [Entry] = [
                Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .systemFavorites),
                Entry(id: "health", title: "图库体检", icon: "stethoscope", item: .systemHealth),
                Entry(id: "ratings", title: "图库整理", icon: "square.grid.2x2", item: .systemRatings),
                Entry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath", item: .systemRevisit)
            ]
            if store.systemDuplicateCount > 0 {
                list.append(Entry(id: "duplicates", title: "重复项目", icon: "square.on.square",
                                  item: .systemDuplicates))
            }
            list += [
                Entry(id: "map", title: "地图", icon: "map", item: .systemMap),
                Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .systemPlaces),
                Entry(id: "people", title: "人物", icon: "person.crop.square", item: .systemPeople),
                Entry(id: "keywords", title: "关键词", icon: "tag", item: .systemKeywords)
            ]
            if store.ocrPhotoCount > 0 {
                list.append(Entry(id: "ocr", title: "包含文字", icon: "text.viewfinder", item: .systemOcrTexts))
            }
            list += [
                Entry(id: "recentlyViewed", title: "最近查看", icon: "eye", item: .systemRecentlyViewed),
                Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .systemEdited),
                Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down",
                      item: .systemRecentlySaved),
                Entry(id: "trash", title: "最近删除", icon: "trash", item: .systemTrash),
                Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square",
                      item: .systemImports)
            ]
            if store.systemHiddenCount > 0 {
                list.append(Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .systemHidden))
            }
            return list
        }
        // 与侧边栏「更多项目」同一顺序、同名、同图标；条件入口也与侧边栏一致。
        var list: [Entry] = [
            Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .favorites),
            Entry(id: "health", title: "图库体检", icon: "stethoscope", item: .health),
            Entry(id: "ratings", title: "图库整理", icon: "square.grid.2x2", item: .ratings),
            Entry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath", item: .revisit)
        ]
        if store.duplicateCount > 0 {
            list.append(Entry(id: "duplicates", title: "重复项目", icon: "square.on.square",
                              item: .duplicates))
        }
        list += [
            Entry(id: "map", title: "地图", icon: "map", item: .map),
            Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .places),
            Entry(id: "people", title: "人物", icon: "person.crop.square", item: .people),
            Entry(id: "keywords", title: "关键词", icon: "tag", item: .keywords)
        ]
        if store.analyzedCount > 0 {
            list.append(Entry(id: "ocr", title: "包含文字", icon: "text.viewfinder", item: .ocrTexts))
        }
        list += [
            Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .recentlyEdited),
            Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down", item: .recentlySaved),
            Entry(id: "trash", title: "最近删除", icon: "trash", item: .trash),
            Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square", item: .imports)
        ]
        if store.hiddenCount > 0 {
            list.append(Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .hidden))
        }
        return list
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 标题由窗口工具栏统一展示，这里只保留入口数量。
                    Text("\(entries.count) 个入口")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // 按可用宽度均分列宽，默认铺满窗口。
                    let spacing: CGFloat = 22
                    let available = max(0, proxy.size.width - 48)
                    let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                    let columnCount = min(store.cardColumns, maxFit)
                    let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                             count: columnCount),
                              alignment: .leading,
                              spacing: 26) {
                        ForEach(entries) { entry in
                            card(entry, width: itemWidth)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func card(_ entry: Entry, width: CGFloat) -> some View {
        let key = entry.id
        let cover = store.moreItemsCover(for: entry.item)
        return VStack(alignment: .leading, spacing: 8) {
            // 与媒体类型 / 场景一致：优先展示该入口的第一张照片缩略图，没有照片时退回图标。
            AlbumCoverImage(photo: cover, side: width, style: .icon(entry.icon))
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            HStack(spacing: 5) {
                Image(systemName: entry.icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: entry.item)
        }
        .help(entry.title)
        .accessibilityLabel(entry.title)
    }
}

/// 系统图库「导入项目」：按官方导入会话（Photos.sqlite 的 `ZGENERICALBUM.ZKIND = 1506`）展示。
/// 与媒体类型 / 场景总览共用同一套卡片墙，标题留给窗口工具栏，内容区不再重复大标题。
struct ImportSessionsOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let sessions = store.systemImportSessions
        CategoryOverviewView(
            entries: sessions.map { session in
                CategoryOverviewEntry(id: "\(session.id)",
                                      title: DateText.fullFormatter.string(from: session.createdAt),
                                      icon: "square.and.arrow.down.on.square",
                                      count: session.count,
                                      cover: store.systemImportSessionCover(session.id),
                                      item: .systemImportSession(session.id))
            },
            emptyIcon: "square.and.arrow.down.on.square",
            emptyTitle: "还没有导入记录",
            emptyMessage: "从相机或存储卡导入照片后，每次导入会显示为一个批次。"
        )
    }
}

/// 系统图库总览：把已连接的官方「照片」图库做成卡片，点卡片切换/浏览。
struct SystemLibrariesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredPath: String?

    private var baseCardWidth: CGFloat {
        min(640, max(240, CGFloat(store.thumbSize) * 2.2))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(baseCardWidth, max(240, proxy.size.width - 48))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统图库")
                            .font(.system(size: 27, weight: .bold))
                        Text("\(store.systemLibraries.count) 个已连接图库")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if store.systemLibraries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                     spacing: 18, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 20) {
                            ForEach(store.systemLibraries) { ref in
                                card(ref, width: cardWidth)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("还没有连接系统图库")
                .font(.system(size: 17, weight: .semibold))
            Text("可以连接本机或其他磁盘上的「照片」图库，只读浏览其中的内容。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("连接照片图库…") { store.presentSystemLibraryPanel() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func card(_ ref: SystemLibraryRef, width: CGFloat) -> some View {
        let isActive = store.systemLibraryPath == ref.path
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                if isActive {
                    if store.isLoadingSystemLibrary {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
            }

            Text(ref.name)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
            Text(ref.path)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hoveredPath == ref.path ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                              lineWidth: hoveredPath == ref.path ? 1.2 : 0.5)
        }
        .scaleEffect(hoveredPath == ref.path && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hoveredPath)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            hoveredPath = hovering ? ref.path : (hoveredPath == ref.path ? nil : hoveredPath)
        }
        .onTapGesture {
            store.activateSystemLibrary(ref)
        }
        .contextMenu {
            Button("在「照片」中打开图库") { store.openSystemLibraryInPhotos(ref.path) }
            Button("在访达中显示图库") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.confirmRemoveSystemLibrary(path: ref.path, name: ref.name)
            }
        }
        .help(ref.path)
        .accessibilityLabel("系统图库 \(ref.name)")
    }
}

/// 网络存储总览：把已接入的网盘 / 共享做成卡片，点卡片打开。
struct CloudStoragesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredID: UUID?
    @State private var renamingMount: CloudMount?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if cloud.mounts.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 272, maximum: 340),
                                                 spacing: 16, alignment: .top)],
                              alignment: .leading,
                              spacing: 16) {
                        ForEach(cloud.mounts) { mount in
                            card(mount)
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("重命名网络存储", isPresented: renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingMount = nil }
            Button("保存") {
                if let mount = renamingMount {
                    store.renameCloudMount(mount.id, to: renameText)
                }
                renamingMount = nil
            }
        } message: {
            Text("只修改显示名称，不会影响网盘上的内容。")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renamingMount != nil },
                set: { if !$0 { renamingMount = nil } })
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("网络存储")
                    .font(.system(size: 27, weight: .bold))
                Text("\(cloud.mounts.count) 个已接入存储 · 点击卡片进入浏览")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                store.presentCloudWizard()
            } label: {
                Label("接入存储", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("通过向导接入 WebDAV、SMB 共享或网盘")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text("还没有网络存储")
                .font(.system(size: 17, weight: .semibold))
            Text("通过向导接入 WebDAV、SMB 共享或阿里云盘 / 百度网盘。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                store.presentCloudWizard()
            } label: {
                Label("网盘接入向导", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .lumaGlassCard(cornerRadius: 22)
    }

    private func card(_ mount: CloudMount) -> some View {
        let isCurrent = store.sidebarItem == .cloudMount(mount.id)
        let hovering = hoveredID == mount.id
        let tint = tint(for: mount.kind)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                iconBadge(mount, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mount.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(mount.kind.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusBadge(isCurrent: isCurrent)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .medium))
                Text(address(for: mount))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.tertiary)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.8)
                .padding(.vertical, 11)

            HStack(spacing: 5) {
                Text(isCurrent ? "正在浏览" : "打开")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .offset(x: hovering ? 2 : 0, y: hovering ? -1 : 0)
                Spacer(minLength: 6)
                Text(createdText(mount))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor(isCurrent: isCurrent, hovering: hovering),
                              lineWidth: isCurrent ? 1.2 : 0.8)
        }
        .scaleEffect(hovering && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { isHovering in
            hoveredID = isHovering ? mount.id : (hoveredID == mount.id ? nil : hoveredID)
        }
        .onTapGesture {
            store.navigate(to: .cloudMount(mount.id))
        }
        .contextMenu {
            Button("打开") { store.navigate(to: .cloudMount(mount.id)) }
            Button("刷新") {
                if isCurrent {
                    store.refreshCloudDirectory()
                } else {
                    store.navigate(to: .cloudMount(mount.id))
                }
            }
            if mount.kind.supportsAccessScope {
                Button("编辑接入范围…") {
                    store.presentCloudWizard(editing: mount)
                }
            }
            Button(connectionActionTitle(for: mount)) {
                if mount.kind == .webdav || mount.kind == .smb {
                    store.presentCloudSheet(mount)
                } else {
                    store.presentCloudWizard(flow: mount.kind.wizardFlow)
                }
            }
            Button("重命名…") {
                renameText = mount.name
                renamingMount = mount
            }
            Divider()
            Button("断开连接", role: .destructive) { store.confirmRemoveCloudMount(mount.id) }
        }
        .help(subtitle(for: mount))
        .accessibilityLabel("网络存储 \(mount.name)")
    }

    private func iconBadge(_ mount: CloudMount, tint: Color) -> some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: 42)
                    .shadow(color: tint.opacity(0.28), radius: 8, y: 3)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.30), Color.clear],
                                             startPoint: .topLeading, endPoint: .center))
                    Image(systemName: mount.kind.symbolName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: tint.opacity(0.5), radius: 6, y: 2)
                }
                .frame(width: 42, height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                }
                .shadow(color: tint.opacity(0.32), radius: 8, y: 3)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(isCurrent: Bool) -> some View {
        if isCurrent {
            HStack(spacing: 4) {
                if cloud.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Text(cloud.loading ? "读取中" : "已打开")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.6)
            }
        } else {
            Text("已接入")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func borderColor(isCurrent: Bool, hovering: Bool) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.55) }
        return hovering ? Color.accentColor.opacity(0.30) : Color.clear
    }

    private func address(for mount: CloudMount) -> String {
        let detail = (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "点击进入浏览云端目录" : detail
    }

    private func createdText(_ mount: CloudMount) -> String {
        "接入于 " + DateText.monthFormatter.string(from: mount.createdAt)
    }

    private func tint(for kind: CloudKind) -> Color {
        switch kind {
        case .webdav: return Color(red: 0.32, green: 0.74, blue: 0.82)
        case .smb: return Color(red: 0.52, green: 0.58, blue: 0.96)
        case .aliyun: return Color(red: 1.00, green: 0.60, blue: 0.30)
        case .baidu: return Color(red: 0.26, green: 0.54, blue: 0.98)
        case .quark: return Color(red: 0.44, green: 0.50, blue: 1.00)
        case .pan115: return Color(red: 0.18, green: 0.56, blue: 0.96)
        }
    }

    private func subtitle(for mount: CloudMount) -> String {
        let detail = (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? mount.kind.title : "\(mount.kind.title) · \(detail)"
    }

    private func connectionActionTitle(for mount: CloudMount) -> String {
        switch mount.kind {
        case .webdav, .smb: return "编辑连接…"
        case .quark, .aliyun, .pan115: return "更新 Cookie…"
        case .baidu: return "重新授权…"
        }
    }
}

/// 无封面时的占位样式：相簿 / 文件夹 / 分类图标。
enum AlbumPlaceholderStyle {
    case album
    case folder
    case icon(String)
}

/// 文件夹封面：2×2 四宫格，每张图各占 25% 面积；不足 4 张的空位用浅色占位。
/// 只有 1 张时直接铺满，避免整块缩略图只亮一小格。
private struct FolderMosaicImage: View {
    let photos: [PhotoItem]
    var side: CGFloat = 220

    var body: some View {
        if photos.isEmpty {
            AlbumPlaceholderArt(style: .folder)
        } else if photos.count == 1, let photo = photos.first {
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
        } else {
            GeometryReader { proxy in
                let gap: CGFloat = 1.5
                let cellWidth = max(1, (proxy.size.width - gap) / 2)
                let cellHeight = max(1, (proxy.size.height - gap) / 2)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(0, width: cellWidth, height: cellHeight)
                        cell(1, width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: gap) {
                        cell(2, width: cellWidth, height: cellHeight)
                        cell(3, width: cellWidth, height: cellHeight)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08))
        }
    }

    @ViewBuilder
    private func cell(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        if index < photos.count {
            PhotoThumbnailView(photo: photos[index], purpose: .cover(min(width, height)))
                .frame(width: width, height: height)
                .clipped()
        } else {
            Color.secondary.opacity(0.08)
                .frame(width: width, height: height)
        }
    }
}

/// 相簿卡片封面：单张图片铺满整张卡片；没有可用照片时显示占位插画。
struct AlbumCoverImage: View {
    let photo: PhotoItem?
    var side: CGFloat = 220
    var style: AlbumPlaceholderStyle = .album

    var body: some View {
        if let photo {
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
        } else {
            AlbumPlaceholderArt(style: style)
        }
    }
}

/// 相簿总览的展示形式切换（网格 / 列表 / 拼贴墙），与「显示 › 相簿显示方式」共用同一个设置。
private struct AlbumDisplayStyleMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            ForEach(AlbumDisplayStyle.allCases) { style in
                Toggle(isOn: Binding(
                    get: { store.albumDisplayStyle == style },
                    set: { isOn in
                        guard isOn else { return }
                        withAnimation(settings.motion.layout) { store.albumDisplayStyle = style }
                    }
                )) {
                    Label(style.title, systemImage: style.icon)
                }
            }
        } label: {
            Image(systemName: store.albumDisplayStyle.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(store.albumDisplayStyle == .grid ? Color.primary : Color.accentColor)
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(store.albumDisplayStyle == .grid
                              ? Color.clear
                              : Color.accentColor.opacity(0.18))
                }
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("相簿显示方式：网格 / 列表 / 拼贴墙")
        .accessibilityLabel("相簿显示方式")
        .accessibilityValue(store.albumDisplayStyle.title)
    }
}

/// 相簿总览列表项：方形封面 + 名称 + 数量，与系统「照片」的列表视图一致（本地与系统图库共用）。
private struct AlbumOverviewRow<MenuContent: View>: View {
    let title: String
    let subtitle: String
    let cover: PhotoItem?
    let placeholder: AlbumPlaceholderStyle
    let side: CGFloat
    var highlighted: Bool = false
    let action: () -> Void
    let menu: MenuContent

    @State private var hovering = false

    init(title: String,
         subtitle: String,
         cover: PhotoItem?,
         placeholder: AlbumPlaceholderStyle,
         side: CGFloat,
         highlighted: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.placeholder = placeholder
        self.side = side
        self.highlighted = highlighted
        self.action = action
        self.menu = menu()
    }

    private var corner: CGFloat { max(10, side * 0.2) }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let cover {
                    PhotoThumbnailView(photo: cover, purpose: .cover(side))
                } else {
                    AlbumPlaceholderArt(style: placeholder)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.10 : (hovering ? 0.04 : 0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.clear,
                              lineWidth: highlighted ? 2 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu { menu }
    }
}

/// 相簿总览拼贴墙方块：无边封面拼贴 + 渐变叠字（本地与系统图库共用）。
private struct AlbumOverviewTile<MenuContent: View>: View {
    @EnvironmentObject private var settings: AppSettings

    let title: String
    let subtitle: String
    let photos: [PhotoItem]
    let placeholder: AlbumPlaceholderStyle
    let side: CGFloat
    let isFolder: Bool
    var highlighted: Bool = false
    let action: () -> Void
    let menu: MenuContent

    @State private var hovering = false

    init(title: String,
         subtitle: String,
         photos: [PhotoItem],
         placeholder: AlbumPlaceholderStyle,
         side: CGFloat,
         isFolder: Bool,
         highlighted: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.subtitle = subtitle
        self.photos = photos
        self.placeholder = placeholder
        self.side = side
        self.isFolder = isFolder
        self.highlighted = highlighted
        self.action = action
        self.menu = menu()
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AlbumCollageCover(photos: photos, side: side, style: placeholder)
                .frame(width: side, height: side)

            LinearGradient(colors: [.clear, .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: isFolder ? "folder.fill" : "rectangle.stack.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(11)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: highlighted ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 14, y: 6)
        .scaleEffect(hovering && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu { menu }
    }
}

/// 相簿总览在列表 / 拼贴墙下的拼贴封面：1 张铺满，2 张左右分栏，3 张左大右二，4 张 2×2。
private struct AlbumCollageCover: View {
    let photos: [PhotoItem]
    let side: CGFloat
    var style: AlbumPlaceholderStyle = .album

    private var items: [PhotoItem] { Array(photos.prefix(4)) }

    var body: some View {
        if items.isEmpty {
            AlbumPlaceholderArt(style: style)
        } else {
            GeometryReader { geo in
                let gap: CGFloat = 1.5
                Group {
                    switch items.count {
                    case 1:
                        cell(items[0])
                    case 2:
                        HStack(spacing: gap) {
                            cell(items[0])
                            cell(items[1])
                        }
                    case 3:
                        HStack(spacing: gap) {
                            cell(items[0])
                            VStack(spacing: gap) {
                                cell(items[1])
                                cell(items[2])
                            }
                        }
                    default:
                        VStack(spacing: gap) {
                            HStack(spacing: gap) {
                                cell(items[0])
                                cell(items[1])
                            }
                            HStack(spacing: gap) {
                                cell(items[2])
                                cell(items[3])
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func cell(_ photo: PhotoItem) -> some View {
        PhotoThumbnailView(photo: photo, purpose: .cover(side / 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

/// 占位插画：柔和强调色渐变底 + 叠放的照片卡片 / 立体文件夹，随卡片尺寸等比缩放。
private struct AlbumPlaceholderArt: View {
    let style: AlbumPlaceholderStyle

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                backdrop(side: side)
                switch style {
                case .album:
                    photoStack(side: side)
                case .folder:
                    folderArt(side: side)
                case .icon(let name):
                    iconArt(name, side: side)
                }
            }
        }
    }

    // MARK: - 背景

    private func backdrop(side: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            LinearGradient(colors: [Color.accentColor.opacity(0.30),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.13), .clear],
                           center: UnitPoint(x: 0.76, y: 0.16),
                           startRadius: 0,
                           endRadius: side * 0.8)
        }
    }

    // MARK: - 相簿：叠放的照片

    private func photoStack(side: CGFloat) -> some View {
        let s = side * 0.62
        let corner = s * 0.09
        return ZStack {
            photoTile(side: s, corner: corner,
                      fill: Color.white.opacity(0.12), glyph: false)
                .frame(width: s * 0.80, height: s * 0.80)
                .rotationEffect(.degrees(-11))
                .offset(x: -s * 0.07, y: s * 0.06)

            photoTile(side: s, corner: corner,
                      fill: Color.white.opacity(0.20), glyph: false)
                .frame(width: s * 0.87, height: s * 0.87)
                .rotationEffect(.degrees(8))
                .offset(x: s * 0.06, y: s * 0.03)

            photoTile(side: s, corner: corner,
                      fill: LinearGradient(colors: [Color.white.opacity(0.95),
                                                    Color.white.opacity(0.74)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                      glyph: true)
                .frame(width: s * 0.92, height: s * 0.92)
                .shadow(color: .black.opacity(0.22), radius: s * 0.07, y: s * 0.03)
        }
    }

    private func photoTile<Fill: ShapeStyle>(side: CGFloat,
                                             corner: CGFloat,
                                             fill: Fill,
                                             glyph: Bool) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
            }
            .overlay {
                if glyph {
                    Image(systemName: "photo.fill")
                        .font(.system(size: side * 0.24, weight: .regular))
                        .foregroundStyle(Color.accentColor.opacity(0.58))
                }
            }
    }

    // MARK: - 文件夹：立体文件夹 + 露出的照片

    private func folderArt(side: CGFloat) -> some View {
        let s = side * 0.64
        let corner = s * 0.10
        return ZStack {
            FolderBackShape(cornerRadius: corner)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.90),
                                              Color.accentColor.opacity(0.48)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.98, height: s * 0.84)
                .offset(y: s * 0.05)
                .shadow(color: .black.opacity(0.22), radius: s * 0.06, y: s * 0.03)

            // 从文件夹里露出的照片（偏右，让左上标签可见）
            RoundedRectangle(cornerRadius: corner * 0.8, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.93),
                                              Color.white.opacity(0.70)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.46, height: s * 0.34)
                .offset(x: s * 0.12, y: -s * 0.06)
                .overlay {
                    Image(systemName: "photo.fill")
                        .font(.system(size: s * 0.11, weight: .regular))
                        .foregroundStyle(Color.accentColor.opacity(0.52))
                        .offset(x: s * 0.12, y: -s * 0.11)
                }

            // 前挡板：半透明高光，让底层强调色透出
            RoundedRectangle(cornerRadius: corner * 1.1, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.30),
                                              Color.white.opacity(0.07)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s, height: s * 0.50)
                .offset(y: s * 0.20)
                .overlay {
                    RoundedRectangle(cornerRadius: corner * 1.1, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(height: 0.8)
                        .padding(.horizontal, corner * 1.4)
                        .offset(y: 0.6)
                }
        }
    }

    // MARK: - 分类图标

    private func iconArt(_ name: String, side: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: side * 0.26, weight: .regular))
            .foregroundStyle(Color.accentColor.opacity(0.85))
            .frame(width: side * 0.46, height: side * 0.46)
            .background(Circle().fill(Color.white.opacity(0.10)))
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
            }
    }
}

/// 文件夹背板：左下主体 + 左上标签，两段圆角矩形合并填充。
private struct FolderBackShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyTop = rect.height * 0.16
        path.addRoundedRect(in: CGRect(x: rect.minX,
                                       y: rect.minY + bodyTop,
                                       width: rect.width,
                                       height: rect.height - bodyTop),
                            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                            style: .continuous)
        path.addRoundedRect(in: CGRect(x: rect.minX,
                                       y: rect.minY,
                                       width: rect.width * 0.55,
                                       height: rect.height * 0.34),
                            cornerSize: CGSize(width: cornerRadius * 0.9, height: cornerRadius * 0.9),
                            style: .continuous)
        return path
    }
}

struct PeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var pinchBase: Double?
    @State private var detailMode: PersonDetailMode = .summary
    @State private var insight: PersonInsight?
    @State private var heroAvatar: NSImage?
    @State private var collapseProgress: CGFloat = 0

    var body: some View {
        if store.isSystemScope {
            if let person = store.selectedPerson {
                personDetail(person)
            } else {
                overview
            }
        } else {
            LocalPeopleView()
        }
    }

    private var people: [SystemPersonInfo] { store.systemPeople }

    /// 人物卡片尺寸跟随工具栏缩放（56…360 → 72…300）。
    private var cardSize: CGFloat {
        min(300, max(72, CGFloat(store.thumbSize)))
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            if people.isEmpty {
                emptyState
            } else if filteredPeople.isEmpty {
                filterEmptyState
            } else {
                systemPeopleBar
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                 spacing: cardSize * 0.16, alignment: .top)],
                              alignment: .leading,
                              spacing: cardSize * 0.2) {
                        ForEach(filteredPeople) { person in
                            PersonCardView(person: person, avatarSize: cardSize * 0.94, style: store.peopleDisplayStyle)
                                .onTapGesture { store.openPerson(person) }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 56)
                }
                .simultaneousGesture(pinchGesture)
            }
        }
    }

    /// 按当前聚合筛选得到的人物；宠物不参与「已命名 / 待命名」。
    /// 「全部」时平铺展示，不再按命名状态分节；只有选了筛选才收窄集合。
    private var filteredPeople: [SystemPersonInfo] {
        switch store.peopleFilter {
        case .all: return people
        case .named: return people.filter { !$0.isUnnamed && !$0.isPet }
        case .unnamed: return people.filter { $0.isUnnamed && !$0.isPet }
        case .pets: return people.filter(\.isPet)
        }
    }

    /// 系统图库的人物由官方识别，这里只提供「刷新读取结果」的入口。
    private var systemPeopleBar: some View {
        HStack(spacing: 10) {
            Text("由 macOS「照片」在端侧识别，拾光只读引用")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                store.refreshSystemPeople()
            } label: {
                Label("刷新识别结果", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("重新读取官方「照片」图库里的人物与宠物")
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
    }

    /// 当前聚合筛选没有结果时的占位；与「图库为空」区分开，避免误以为识别失败。
    private var filterEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.peopleFilter.icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.peopleFilter.emptyTitle)
                .font(.system(size: 16, weight: .semibold))
            Text(store.peopleFilter.emptyHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private var emptyState: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.14), Color.clear],
                           startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 96, height: 96)
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text("人物与宠物")
                    .font(.system(size: 22, weight: .semibold))
                Text("连接 macOS 官方「照片」图库后，这里会显示官方端侧识别出的人物与宠物（含尚未命名的聚类）；识别始终在本机完成，本 App 不会上传任何照片。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                HStack(spacing: 18) {
                    featureChip(icon: "lock.shield", title: "端侧识别")
                    featureChip(icon: "person.2", title: "官方结果")
                    featureChip(icon: "photo.on.rectangle", title: "只读引用")
                }
                .padding(.top, 4)

                Button {
                    store.refreshSystemPeople()
                } label: {
                    Label("刷新识别结果", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(30)
        }
    }

    private func personDetail(_ person: SystemPersonInfo) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PersonDetailHero(name: person.name,
                                 subtitle: insight?.subtitle ?? "正在整理这段影像…",
                                 avatar: heroAvatar,
                                 isPet: person.isPet,
                                 cover: insight?.coverPhoto
                                    ?? person.keyAssetID.flatMap { store.anyPhoto(id: $0) },
                                 mode: detailMode,
                                 collapse: detailMode == .map ? 1 : collapseProgress,
                                 onBack: { store.closePerson() },
                                 onModeChange: { newMode in
                                     withAnimation(.snappy(duration: 0.26)) { detailMode = newMode }
                                 })

                if detailMode == .map {
                    // 地图档：页头收成一条紧凑栏，剩下的空间全部交给地图。
                    PersonMapPanel(source: .system(person), name: person.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            PersonScrollTracker(coordinateSpace: "systemPersonScroll")
                            if detailMode == .summary {
                                if let insight {
                                    PersonInsightSummaryView(insight: insight, name: person.name)
                                } else {
                                    insightLoading.frame(height: 360)
                                }
                            } else {
                                allPhotos(availableWidth: proxy.size.width,
                                          fillHeight: proxy.size.height)
                            }
                        }
                        .id(detailMode)
                    }
                    .coordinateSpace(name: "systemPersonScroll")
                    .onPreferenceChange(PersonScrollOffsetKey.self) { offset in
                        let value = min(1, max(0, offset / 180))
                        if abs(value - collapseProgress) > 0.004 {
                            collapseProgress = value
                        }
                    }
                }
            }
        }
        .task(id: person.id) {
            detailMode = .summary
            collapseProgress = 0
            insight = nil
            let request = PersonAvatarLoader.request(for: person, size: 84)
            heroAvatar = PersonAvatarLoader.cached(request)
            if heroAvatar == nil {
                heroAvatar = await PersonAvatarLoader.load(request, store: store)
            }
            let loaded = await store.systemPersonInsightAsync(for: person)
            if !Task.isCancelled, store.selectedPerson?.id == person.id {
                insight = loaded
            }
        }
        .onChange(of: store.selectedPerson?.id) { _, _ in
            detailMode = .summary
            collapseProgress = 0
            insight = nil
        }
    }

    private var insightLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在整理这段影像故事…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「全部」：瀑布流拼贴，卡片保留原始比例并常驻投影。
    private func allPhotos(availableWidth: CGFloat, fillHeight: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("全部影像")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(store.visibleCount.formatted()) 张")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)

            MasonryPhotoGrid(photos: store.visiblePhotos,
                             availableWidth: availableWidth,
                             targetWidth: CGFloat(store.thumbSize) * 1.25)
        }
        .padding(.bottom, 56)
        .photoMarqueeSelection(fillHeight: fillHeight)
    }

    private func featureChip(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(width: 84, height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PersonAvatarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let person: SystemPersonInfo
    let size: CGFloat
    /// 头像形状：圆形或圆角方形；默认圆形（详情页等场景沿用圆形）。
    var style: PeopleDisplayStyle = .circle

    @State private var image: NSImage?

    private var request: PersonAvatarRequest {
        PersonAvatarLoader.request(for: person, size: size)
    }

    /// 裁切形状：圆角方形沿用全局卡片圆角设置。
    private var shape: AnyShape {
        switch style {
        case .circle: AnyShape(Circle())
        case .roundedSquare: AnyShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        }
    }

    var body: some View {
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.25)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: person.isPet ? "pawprint.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .task(id: request) {
            if let cached = PersonAvatarLoader.cached(request) {
                image = cached
                return
            }
            image = await PersonAvatarLoader.load(request, store: store)
        }
    }
}

private struct PersonCardView: View {
    let person: SystemPersonInfo
    /// 头像直径，随工具栏缩放变化。
    var avatarSize: CGFloat = 124
    /// 头像形状（圆形 / 圆角方形），随当前图库保存。
    var style: PeopleDisplayStyle = .circle

    var body: some View {
        PeoplePersonCardShell(name: person.name, count: person.faceCount) {
            PersonAvatarView(person: person, size: avatarSize, style: style)
        }
    }
}
