import Foundation

/// 启动首屏的窗口快照：把上次退出前「所有照片」的第一页存进图库自己的设置表。
///
/// 第二次打开图库时先铺上这批照片（缩略图本身也有磁盘缓存），随后真实的 SQLite
/// 查询在后台完成并整体替换。快照只用于首屏过渡：内容版本变化后 `query.key` 不再匹配，
/// 不会被误用；超过保留期也直接丢弃。
struct WindowSnapshot {
    var key: String
    var photos: [PhotoItem]
    var total: Int
    var videos: Int
    var savedAt: Date
}

enum WindowSnapshotStore {
    /// 元信息：`<query.key>|<savedAt 秒>`。先比对这个键，命中才去解码照片数组。
    static let metaKey = "window.snapshot.meta.v1"
    static let payloadKey = "window.snapshot.payload.v1"
    /// 与分页第一页一致：马赛克档位下一屏能铺到上千格，快照太少会露出空白。
    static let maxPhotos = 600
    static let maxAge: TimeInterval = 60 * 60 * 24 * 30

    private struct Payload: Codable {
        var photos: [PhotoItem]
        var total: Int
        var videos: Int
    }

    static func load(from store: MetadataStore?) -> WindowSnapshot? {
        guard let store,
              let meta = store.setting(metaKey) else { return nil }
        let parts = meta.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let stamp = Double(parts[1]) else { return nil }
        let savedAt = Date(timeIntervalSince1970: stamp)
        guard -savedAt.timeIntervalSinceNow < maxAge,
              let raw = store.setting(payloadKey),
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.photos.isEmpty else { return nil }
        return WindowSnapshot(key: parts[0], photos: payload.photos,
                              total: payload.total, videos: payload.videos, savedAt: savedAt)
    }

    /// 编码与落盘都放到后台：首屏加载不能被一次 JSON 编码拖慢。
    static func save(key: String, photos: [PhotoItem], total: Int, videos: Int,
                     to store: MetadataStore, tasks: StoreTaskCenter) {
        let payload = Payload(photos: Array(photos.prefix(maxPhotos)), total: total, videos: videos)
        let meta = "\(key)|\(Date().timeIntervalSince1970)"
        tasks.attach(.windowSnapshot, Task {
            let json = await Task.detached(priority: .utility) {
                (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
            }.value
            guard !Task.isCancelled, let json else { return }
            store.setSettingAsync(payloadKey, json)
            store.setSettingAsync(metaKey, meta)
        })
    }
}

extension LibraryStore {
    /// 首屏快照：只在「窗口为空、还没真正加载、没有指定滚动目标」时铺一次。
    func hydrateWindowSnapshotIfNeeded(query: PhotoQuery) {
        guard isPagedScope, !isSystemPagedScope, !isCloudScope,
              windowPhotos.isEmpty, !hasLoadedWindow, scrollTargetID == nil else { return }
        guard let snapshot = WindowSnapshotStore.load(from: metadataStore),
              snapshot.key == query.key else { return }
        windowPhotos = snapshot.photos
        windowTotal = snapshot.total
        windowVideos = snapshot.videos
        windowStartOffset = 0
        windowRevision &+= 1
        // 标记成「同一查询」：否则紧接着的 reload 会把刚铺上的快照当成旧范围清空。
        windowQueryKey = query.key
        // 故意不置 hasLoadedWindow：真实查询回来后整体替换，滚动与取页仍以真数据为准。
    }

    /// 第一页落地后保存快照（后台编码 + 异步写设置表）。
    func saveWindowSnapshotIfNeeded(query: PhotoQuery, start: Int, replace: Bool) {
        guard replace, start == 0, isPagedScope, !isSystemPagedScope,
              let store = metadataStore, !windowPhotos.isEmpty else { return }
        WindowSnapshotStore.save(key: query.key,
                                 photos: windowPhotos,
                                 total: windowTotal,
                                 videos: windowVideos,
                                 to: store,
                                 tasks: tasks)
    }
}
