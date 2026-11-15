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
            AlbumCoverImage(photo: photo, side: width, style: .folder)
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

/// 官方「照片」图库里的文件夹：只展示下一层的子文件夹与相簿（与系统「照片」一致），只读。
struct SystemFolderOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// 为空时展示系统图库根层（「相簿」分区总览）。
    var folderID: Int64? = nil

    @State private var hoveredKey: String?

    /// 卡片宽度跟随工具栏缩放（56…360 pt）映射到约 130…640 pt，与「所有相簿」一致。
    private var baseCardWidth: CGFloat {
        min(640, max(130, CGFloat(store.thumbSize) * 2.2))
    }

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
            let cardWidth = min(baseCardWidth, max(150, proxy.size.width - 48))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if entries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                     spacing: 22, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(childFolders) { child in
                                folderCard(child, width: cardWidth)
                            }
                            ForEach(childAlbums) { album in
                                albumCard(album, width: cardWidth)
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

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder?.name ?? "相簿")
                    .font(.system(size: 27, weight: .bold))
                Text("\(childAlbums.count) 个相簿, \(childFolders.count) 个子文件夹")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
    }

    private var parentTitle: String {
        guard let folder,
              let parentID = folder.parent,
              let parent = store.systemFolders.first(where: { $0.id == parentID }) else {
            return store.systemLibraryName ?? "所有项目"
        }
        return parent.name
    }

    private func navigateUp() {
        guard let folder else {
            // 根层「相簿」总览：返回系统图库的所有项目。
            store.navigate(to: .systemLibrary)
            return
        }
        if let parentID = folder.parent,
           store.systemFolders.contains(where: { $0.id == parentID }) {
            store.navigate(to: .systemFolder(parentID))
        } else {
            store.navigate(to: .systemLibrary)
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

    private func firstPhoto(in ids: [UUID]) -> PhotoItem? {
        for id in ids {
            if let photo = store.systemPhoto(id: id), photo.deletedAt == nil, !photo.isHidden {
                return photo
            }
        }
        return nil
    }

    private func albumCover(_ album: SystemAlbumInfo) -> PhotoItem? {
        firstPhoto(in: album.assetIDs)
    }

    /// 子文件夹封面取自身与更深层中第一个有内容的相簿；限制递归深度，避免遍历异常结构。
    private func folderCover(_ id: Int64, depth: Int = 0) -> PhotoItem? {
        guard depth < 4 else { return nil }
        for entry in store.systemChildren(of: id) {
            switch entry {
            case .album(let album):
                if let photo = albumCover(album) { return photo }
            case .folder(let child):
                if let photo = folderCover(child.id, depth: depth + 1) { return photo }
            }
        }
        return nil
    }

    // MARK: - 卡片

    private func folderCard(_ child: SystemFolderInfo, width: CGFloat) -> some View {
        let key = "folder-\(child.id)"
        return cardBody(key: key,
                        title: child.name,
                        cover: folderCover(child.id),
                        placeholder: .folder,
                        width: width) {
            store.navigate(to: .systemFolder(child.id))
        } contextMenu: {
            Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
            Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    private func albumCard(_ album: SystemAlbumInfo, width: CGFloat) -> some View {
        let key = "album-\(album.id)"
        return cardBody(key: key,
                        title: album.name,
                        cover: albumCover(album),
                        placeholder: .album,
                        width: width) {
            store.navigate(to: .systemAlbum(album.id))
        } contextMenu: {
            Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
            Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    private func cardBody<MenuContent: View>(key: String,
                                             title: String,
                                             cover: PhotoItem?,
                                             placeholder: AlbumPlaceholderStyle,
                                             width: CGFloat,
                                             action: @escaping () -> Void,
                                             @ViewBuilder contextMenu: () -> MenuContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: cover, side: width, style: placeholder)
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

/// 媒体类型总览：卡片墙展示各分类的数量与封面（侧边栏「媒体类型」分区头点开）。
struct MediaTypesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.mediaTypeSummary
        let system = store.isSystemScope
        let keys = (system ? MediaTypeKey.allCases : MediaTypeKey.localCases)
            .filter { (summary.counts[$0] ?? 0) > 0 }
        CategoryOverviewView(
            heading: "媒体类型",
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

/// 场景总览：卡片墙展示端侧分析出的场景分类（侧边栏「场景」分区头点开）。
struct ScenesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.sceneSummary
        let categories = SceneCatalog.categories.filter { (summary.counts[$0.id] ?? 0) > 0 }
        CategoryOverviewView(
            heading: "场景",
            entries: categories.map { category in
                CategoryOverviewEntry(id: category.id,
                                      title: category.title,
                                      icon: category.icon,
                                      count: summary.counts[category.id] ?? 0,
                                      cover: summary.covers[category.id],
                                      item: .scene(category.id))
            },
            emptyIcon: "sparkles",
            emptyTitle: store.analyzedCount == 0 ? "还没有分析照片内容" : "未识别到常见场景",
            emptyMessage: "识别场景与照片中的文字，全部在本机完成。",
            emptyActionTitle: store.isAnalyzingIntelligence ? nil : "分析照片内容…",
            emptyAction: { store.analyzeIntelligence() }
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
    let heading: String
    let entries: [CategoryOverviewEntry]
    let emptyIcon: String
    let emptyTitle: String
    let emptyMessage: String
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredKey: String?

    /// 卡片宽度跟随工具栏缩放（56…360 pt）映射到约 130…640 pt。
    private var baseCardWidth: CGFloat {
        min(640, max(130, CGFloat(store.thumbSize) * 2.2))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(baseCardWidth, max(150, proxy.size.width - 48))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heading)
                            .font(.system(size: 27, weight: .bold))
                        Text("\(entries.count) 个分类")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if entries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                     spacing: 22, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(entries) { entry in
                                card(entry, width: cardWidth)
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
            return [
                Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .systemFavorites),
                Entry(id: "trash", title: "最近删除", icon: "trash", item: .systemTrash),
                Entry(id: "duplicates", title: "重复项目", icon: "square.on.square", item: .systemDuplicates),
                Entry(id: "handwriting", title: "手写", icon: "pencil.tip", item: .systemHandwriting),
                Entry(id: "illustrations", title: "插图", icon: "scribble.variable", item: .systemIllustrations),
                Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down", item: .systemRecentlySaved),
                Entry(id: "recentlyViewed", title: "最近查看", icon: "eye", item: .systemRecentlyViewed),
                Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .systemEdited),
                Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square", item: .systemImports),
                Entry(id: "map", title: "地图", icon: "map", item: .systemMap),
                Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .systemPlaces),
                Entry(id: "people", title: "人物", icon: "person.2", item: .systemPeople),
                Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .systemHidden)
            ]
        }
        return [
            Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .favorites),
            Entry(id: "trash", title: "最近删除", icon: "trash", item: .trash),
            Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down", item: .recentlySaved),
            Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .recentlyEdited),
            Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square", item: .imports),
            Entry(id: "ocr", title: "包含文字", icon: "text.viewfinder", item: .ocrTexts),
            Entry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath", item: .revisit),
            Entry(id: "health", title: "图库体检", icon: "stethoscope", item: .health),
            Entry(id: "map", title: "地图", icon: "map", item: .map),
            Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .places),
            Entry(id: "people", title: "人物", icon: "person.crop.square", item: .people),
            Entry(id: "duplicates", title: "重复项目", icon: "square.on.square", item: .duplicates),
            Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .hidden)
        ]
    }

    private var baseCardWidth: CGFloat {
        min(640, max(200, CGFloat(store.thumbSize) * 2.2))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(baseCardWidth, max(200, proxy.size.width - 48))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("更多项目")
                            .font(.system(size: 27, weight: .bold))
                        Text("\(entries.count) 个入口")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                 spacing: 14, alignment: .top)],
                              alignment: .leading,
                              spacing: 14) {
                        ForEach(entries) { entry in
                            card(entry, width: cardWidth)
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
        return HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: 68)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hoveredKey == key ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                              lineWidth: hoveredKey == key ? 1.2 : 0.5)
        }
        .shadow(color: .black.opacity(hoveredKey == key ? 0.14 : 0), radius: 10, y: 4)
        .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hoveredKey)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Button("断开连接", role: .destructive) { store.removeSystemLibrary(ref.path) }
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

    private var baseCardWidth: CGFloat {
        min(640, max(240, CGFloat(store.thumbSize) * 2.2))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(baseCardWidth, max(240, proxy.size.width - 48))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("网络存储")
                            .font(.system(size: 27, weight: .bold))
                        Text("\(cloud.mounts.count) 个已接入存储")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if cloud.mounts.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth),
                                                     spacing: 18, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 20) {
                            ForEach(cloud.mounts) { mount in
                                card(mount, width: cardWidth)
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
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("还没有网络存储")
                .font(.system(size: 17, weight: .semibold))
            Text("通过向导接入 WebDAV、SMB 共享或阿里云盘 / 百度网盘。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("网盘接入向导…") { store.presentCloudWizard() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func card(_ mount: CloudMount, width: CGFloat) -> some View {
        let isCurrent = store.sidebarItem == .cloudMount(mount.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: icon(for: mount.kind))
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                if isCurrent {
                    Text(cloud.loading ? "读取中" : "已打开")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }

            Text(mount.name)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
            Text(subtitle(for: mount))
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
                .strokeBorder(hoveredID == mount.id ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                              lineWidth: hoveredID == mount.id ? 1.2 : 0.5)
        }
        .scaleEffect(hoveredID == mount.id && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hoveredID)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            hoveredID = hovering ? mount.id : (hoveredID == mount.id ? nil : hoveredID)
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
            Button(mount.kind.usesOAuth ? "重新授权…" : "编辑连接…") {
                if mount.kind.usesOAuth {
                    store.presentCloudWizard(flow: mount.kind == .aliyun ? .aliyun : .baidu)
                } else {
                    store.presentCloudSheet(mount)
                }
            }
            Divider()
            Button("断开连接", role: .destructive) { store.removeCloudMount(mount.id) }
        }
        .help(subtitle(for: mount))
        .accessibilityLabel("网络存储 \(mount.name)")
    }

    private func subtitle(for mount: CloudMount) -> String {
        mount.kind.title + " · " + (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
    }

    private func icon(for kind: CloudKind) -> String {
        switch kind {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "network"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        }
    }
}

/// 无封面时的占位样式：相簿 / 文件夹 / 分类图标。
private enum AlbumPlaceholderStyle {
    case album
    case folder
    case icon(String)
}

/// 相簿 / 文件夹卡片封面：单张图片铺满整张卡片；没有可用照片时显示占位插画。
private struct AlbumCoverImage: View {
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
