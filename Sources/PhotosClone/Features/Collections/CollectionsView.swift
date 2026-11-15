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
                            Color.black.opacity(0.18)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("精选集")
                        .font(.system(size: 27, weight: .bold))
                    Text("智能汇总你的照片、视频与编辑成果")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

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
                    .foregroundStyle(.white.opacity(0.7))
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

    /// 卡片宽度跟随工具栏缩放（56…360 pt）映射到约 130…640 pt。
    private var baseCardWidth: CGFloat {
        min(640, max(130, CGFloat(store.thumbSize) * 2.2))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(baseCardWidth, max(150, proxy.size.width - 48))
            let liveByID = livePhotoIndex
            let childFolders = visibleFolders
            let childAlbums = visibleAlbums
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if childFolders.isEmpty && childAlbums.isEmpty {
                        emptyState
                    } else {
                        let folderCovers = folderCoverMap(childFolders, liveByID: liveByID)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                     spacing: 22, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(childFolders) { folder in
                                folderCard(folder, width: cardWidth,
                                           photo: folderCovers[folder.id])
                            }
                            ForEach(childAlbums) { album in
                                albumCard(album, width: cardWidth,
                                          photo: albumCover(album, liveByID: liveByID))
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
        .sheet(item: $namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folderName ?? "相簿")
                    .font(.system(size: 27, weight: .bold))
                Text("\(visibleAlbums.count) 个相簿, \(visibleFolders.count) 个文件夹")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if folderID != nil {
                Button {
                    navigateUp()
                } label: {
                    Label(parentTitle, systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("返回\(parentTitle)")
            }
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

    private var folderName: String? {
        guard let folderID else { return nil }
        return store.folders.first(where: { $0.id == folderID })?.name
    }

    private var parentTitle: String {
        guard let folderID,
              let folder = store.folders.first(where: { $0.id == folderID }),
              let parentID = folder.parentID else { return "所有相簿" }
        return store.folders.first(where: { $0.id == parentID })?.name ?? "所有相簿"
    }

    private func navigateUp() {
        guard let folderID,
              let folder = store.folders.first(where: { $0.id == folderID }) else { return }
        if let parentID = folder.parentID {
            store.navigate(to: .folder(parentID))
        } else {
            store.navigate(to: .allAlbums)
        }
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

    /// 文件夹封面取自身与所有子文件夹中第一个相簿的封面。
    private func folderCoverMap(_ folders: [AlbumFolder],
                                liveByID: [UUID: PhotoItem]) -> [UUID: PhotoItem] {
        var result: [UUID: PhotoItem] = [:]
        for folder in folders {
            let folderIDs = store.folderSubtreeIDs(folder.id)
            for album in store.albums where album.folderID.map({ folderIDs.contains($0) }) ?? false {
                if let cover = albumCover(album, liveByID: liveByID) {
                    result[folder.id] = cover
                    break
                }
            }
        }
        return result
    }

    // MARK: - 卡片

    private func folderCard(_ folder: AlbumFolder, width: CGFloat, photo: PhotoItem?) -> some View {
        let key = "folder-\(folder.id.uuidString)"
        return VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: photo, side: width)
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
            Button("打开文件夹") { store.navigate(to: .folder(folder.id)) }
            Divider()
            Button("新建相簿…") { namePrompt = .newAlbum(folderID: folder.id) }
            Button("新建子文件夹…") { namePrompt = .newFolder(parentID: folder.id) }
            Divider()
            Button("重命名文件夹…") { namePrompt = .renameFolder(folder.id, current: folder.name) }
            Button("删除文件夹", role: .destructive) { store.deleteFolder(folder.id) }
        }
        .accessibilityLabel("文件夹 \(folder.name)")
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
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { dropTargetAlbumID == album.id },
            set: { targeted in
                if targeted {
                    dropTargetAlbumID = album.id
                } else if dropTargetAlbumID == album.id {
                    dropTargetAlbumID = nil
                }
            }
        )) { providers in
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

/// 相簿 / 文件夹卡片封面：单张图片铺满整张卡片；没有可用照片时显示占位。
private struct AlbumCoverImage: View {
    let photo: PhotoItem?
    var side: CGFloat = 220

    var body: some View {
        if let photo {
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
        } else {
            Color(nsColor: .quaternaryLabelColor).opacity(0.22)
                .overlay {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

struct PeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var hoveredID: Int64?
    @State private var pinchBase: Double?

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
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("人物与宠物")
                        .font(.system(size: 28, weight: .bold))
                    Text("来自系统图库的端侧识别结果 · \(people.count) 位")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if people.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                 spacing: cardSize * 0.16, alignment: .top)],
                              alignment: .leading,
                              spacing: cardSize * 0.2) {
                        ForEach(people) { person in
                            PersonCardView(person: person,
                                           avatarSize: cardSize * 0.94,
                                           isHovered: hoveredID == person.id)
                                .onTapGesture { store.openPerson(person) }
                                .onHover { hovering in
                                    hoveredID = hovering ? person.id : (hoveredID == person.id ? nil : hoveredID)
                                }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 4)
                    .padding(.bottom, 56)
                }
                .simultaneousGesture(pinchGesture)
            }
        }
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
                Text("连接 macOS 官方「照片」图库后，这里会显示官方端侧已命名的人物与宠物；识别始终在本机完成，本 App 不会上传任何照片。")
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
            }
            .padding(30)
        }
    }

    private func personDetail(_ person: SystemPersonInfo) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        store.closePerson()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("返回人物")
                    .accessibilityLabel("返回人物")

                    PersonAvatarView(person: person, size: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.system(size: 21, weight: .bold))
                        Text("\(store.visiblePhotos.count.formatted()) 张照片")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    SquarePhotoGrid(photos: store.visiblePhotos, availableWidth: proxy.size.width)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                }
            }
        }
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
    let person: SystemPersonInfo
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.25)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let image = avatarImage {
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
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var avatarImage: NSImage? {
        if let data = person.cropData, let image = NSImage(data: data) {
            return image
        }
        guard let id = person.keyAssetID ?? person.assetIDs.first,
              let photo = store.anyPhoto(id: id) else { return nil }
        return ImageLoader.gridThumbnail(for: photo, maxPixel: 256)
    }
}

private struct PersonCardView: View {
    @EnvironmentObject private var store: LibraryStore
    let person: SystemPersonInfo
    /// 头像直径，随工具栏缩放变化。
    var avatarSize: CGFloat = 124
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 10) {
            PersonAvatarView(person: person, size: avatarSize)
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.10),
                        radius: isHovered ? 14 : 6,
                        y: isHovered ? 7 : 3)
            Text(person.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(person.faceCount.formatted()) 张照片")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
    }
}
