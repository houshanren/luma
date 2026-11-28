import Foundation

/// 统一搜索命中的打开路由：搜索结果页与智能助手共用同一套跳转，避免两处各写一份。
extension LibraryStore {
    /// 打开一条统一搜索命中：照片进查看器、结构项切页面、影音条目进入详情或播放。
    func openSearchHit(_ hit: SearchHit) {
        switch hit.payload {
        case .photo(let id):
            openViewer(id)

        case .localAlbum(let id):
            navigate(to: .album(id))

        case .localFolder(let id):
            navigate(to: .folder(id))

        case .systemAlbum(let id):
            navigate(to: .systemAlbum(id))

        case .systemFolder(let id):
            navigate(to: .systemFolder(id))

        case .localPerson(let id):
            navigate(to: .people)
            selectedLocalPersonID = id

        case .systemPerson(let person):
            navigate(to: .systemPeople)
            openPerson(person)

        case .place(let cluster):
            navigate(to: isSystemScope ? .systemPlaces : .places)
            openPlace(cluster)

        case .scene(let id):
            // 场景分类直达：系统图库有自己的场景入口。
            navigate(to: isSystemScope ? .systemScene(id) : .scene(id))

        case .cloudFile(let mountID, let folderPath, let path):
            // 直达文件本身：打开挂载与所在目录后，直接把这一项送进查看器。
            openCloudFile(mountID: mountID, folderPath: folderPath, path: path)

        case .cloudFolder(let mountID, let path):
            openCloudMount(mountID)
            selectCloudFolder(path: path)

        case .cinema(let scopeKey, let queueTitle, let entry):
            openCinemaSearchHit(scopeKey: scopeKey, queueTitle: queueTitle, entry: entry)

        case .channel(let channel):
            tvModel.focusPlaylist(channel.playlistID)
            tvModel.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            tvModel.setHubTab(.channels)
            navigate(to: .iptv)
            openTVChannel(channel)

        case .program(let channel, let program):
            tvModel.focusPlaylist(channel.playlistID)
            navigate(to: .iptv)
            if program.isLive {
                tvModel.setHubTab(.channels)
                openTVChannel(channel)
            } else if program.end <= Date(), !(channel.catchUpSource ?? "").isEmpty {
                // 已经播完且源支持回看：直接回看这一档。
                openTVCatchup(channel, program: program)
            } else {
                // 未开播 / 该源不能回看：停在这档节目当天的节目单上。
                let today = Calendar.current.startOfDay(for: Date())
                let day = Calendar.current.startOfDay(for: program.start)
                let offset = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
                tvModel.guideDayOffset = min(2, max(-2, offset))
                tvModel.setHubTab(.guide)
            }

        case .catalogItem(let sourceID, let item):
            // 进入频道页时它会先复位内联详情：必须走「待打开条目」，
            // 由频道页自己的 task 消费，才能一进来就停在详情页。
            catalogModel.pendingInlineItem = item
            catalogModel.focus(sourceID)
            navigate(to: .catalogSource(sourceID))

        case .networkCinemaItem(let sourceID, let item, let isTV):
            // 与网络资源同样的思路：网络影院页出现时消费「待打开条目」，直接进详情。
            networkCinemaSourceID = sourceID
            networkCinemaTab = isTV ? .shows : .movies
            if let source = catalogModel.cinemaSources.first(where: { $0.id == sourceID }) {
                networkCinemaPendingItem = NetworkCinemaItem(source: source,
                                                             item: item,
                                                             isTV: isTV)
            }
            navigate(to: .networkCinema)

        case .atlasPerson(let id):
            // 星图页面出现时消费「待看人物」：切到档案并选中这一位。
            AtlasStore.shared.pendingPersonID = id
            navigate(to: .atlas)

        case .atlasWork(let id):
            AtlasStore.shared.pendingWorkID = id
            navigate(to: .atlas)
        }
    }

    /// 影院命中：切到对应影院范围，并按片名还原播放队列。
    private func openCinemaSearchHit(scopeKey: String,
                                     queueTitle: String,
                                     entry: CinemaEntry) {
        let mountID = Self.cinemaMountID(from: scopeKey)
        if let mountID {
            navigate(to: .cloudCinema(mountID))
        } else {
            navigate(to: .cinema)
        }
        let scope: CinemaScope = mountID.map { CinemaScope.mount($0) } ?? .local
        let queue = (cinemaIndexes[scope] ?? [:])
            .values
            .filter { $0.title == queueTitle }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        openCinema(entry, queue: queue.isEmpty ? nil : queue)
    }

    private static func cinemaMountID(from scopeKey: String) -> UUID? {
        let prefix = "mount-"
        guard scopeKey.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(scopeKey.dropFirst(prefix.count)))
    }
}
