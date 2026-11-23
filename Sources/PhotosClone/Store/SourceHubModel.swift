import Foundation
import LumaContentCore

/// 源运行时的唯一入口：
/// - `state`：统一注册表（由各模块的当前状态构建），侧边栏与搜索都读它。
/// - `activate(_:)`：链接图库换库，其余 kind 只切浏览上下文，不再由视图各自判断。
/// - `session(for:)`：按源拿到 `SourceSession`，回答“当前浏览哪个源、健康状态如何”。
@MainActor
final class SourceHubModel: ObservableObject {
    private unowned let store: LibraryStore
    /// 同一种源只创建一个会话，避免每次切换都重建连接状态。
    private var sessions: [String: any SourceSession] = [:]

    /// 最近一次激活的源会话；后续状态条 / 侧边栏角标直接读它。
    @Published private(set) var activeSession: (any SourceSession)?

    init(store: LibraryStore) {
        self.store = store
    }

    var state: SourceRegistryState { store.buildSourceRegistryState() }

    var currentBrowseSourceID: SourceID? { state.activeBrowseSourceID }

    // MARK: - 激活

    /// 点击源时唯一的入口。语义由源 ID 的 kind 决定；
    /// 影院入口不依赖注册表里是否已有条目（空影院也要能点进去扫描）。
    func activate(_ sourceID: SourceID) {
        switch Self.kind(of: sourceID) {
        case .library:
            activateLibrary(sourceID)
        case .cloudMount:
            guard let mountID = Self.uuid(in: sourceID, prefix: "cloud:") else { return }
            store.navigate(to: .cloudMount(mountID))
        case .catalogSite:
            guard let id = Self.uuid(in: sourceID, prefix: "catalog:") else { return }
            store.catalogModel.focus(id)
            store.navigate(to: .catalogSource(id))
        case .cinemaFeed:
            if sourceID == .localCinema {
                store.activateCinemaScope(.local)
                store.navigate(to: .cinema)
            } else if let mountID = Self.uuid(in: sourceID, prefix: "cinema:mount:") {
                store.activateCinemaScope(.mount(mountID))
                store.navigate(to: .cloudCinema(mountID))
            }
        case .iptv, .localDisk:
            // 契约已就位，功能还没接入：明确提示，避免点了没反应。
            store.showToast("\(Self.kind(of: sourceID).title)将在后续版本接入")
            return
        }

        if let session = session(for: sourceID) {
            activeSession = session
            Task { await session.activate() }
        } else {
            activeSession = nil
        }
    }

    /// 链接图库：替换当前图库会话；当前图库本身只回到图库浏览。
    private func activateLibrary(_ sourceID: SourceID) {
        let path = String(sourceID.rawValue.dropFirst("library:".count))
        if let ref = store.systemLibraries.first(where: { $0.path == path }) {
            store.activateSystemLibrary(ref)
            return
        }
        let containerPath = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
        if containerPath == URL(fileURLWithPath: path).standardizedFileURL.path {
            store.navigate(to: .library)
        } else {
            store.switchLibraryContainer(URL(fileURLWithPath: path))
        }
    }

    // MARK: - 会话

    /// 源对应的只读内容仓库；云盘 / 资源已接入，图库与后续 kind 由各自模型补齐。
    func repository(for sourceID: SourceID) -> (any ContentRepository)? {
        switch Self.kind(of: sourceID) {
        case .cloudMount:
            guard let id = Self.uuid(in: sourceID, prefix: "cloud:"),
                  let mount = store.cloudMounts.first(where: { $0.id == id }) else { return nil }
            return CloudContentRepository(mount: mount, rootPath: store.cloudRootPath(for: mount))
        case .catalogSite:
            guard let id = Self.uuid(in: sourceID, prefix: "catalog:"),
                  let source = store.catalogModel.sources.first(where: { $0.id == id }) else { return nil }
            return CatalogContentRepository(source: source)
        case .cinemaFeed:
            let scope: CinemaScope = sourceID == .localCinema
                ? .local
                : (sourceID.uuidValue.map(CinemaScope.mount) ?? .local)
            return CinemaContentRepository(store: store, scope: scope)
        case .library:
            return LibraryContentRepository(store: store, sourceID: sourceID)
        case .iptv, .localDisk:
            // 电视 / 磁盘后续补。
            return nil
        }
    }

    func session(for sourceID: SourceID) -> (any SourceSession)? {
        if let cached = sessions[sourceID.rawValue] { return cached }
        guard let descriptor = state.descriptor(for: sourceID) else { return nil }
        let session: (any SourceSession)?
        switch descriptor.kind {
        case .library:
            session = LibrarySourceSession(store: store, descriptor: descriptor)
        case .cloudMount:
            session = Self.uuid(in: sourceID, prefix: "cloud:").map {
                CloudSourceSession(store: store, mountID: $0, descriptor: descriptor)
            }
        case .catalogSite:
            session = Self.uuid(in: sourceID, prefix: "catalog:").map {
                CatalogSourceSession(store: store, sourceID: $0, descriptor: descriptor)
            }
        case .cinemaFeed:
            session = CinemaSourceSession(store: store, descriptor: descriptor)
        default:
            session = nil
        }
        if let session { sessions[sourceID.rawValue] = session }
        return session
    }

    // MARK: - SourceID 解析

    private static func kind(of sourceID: SourceID) -> SourceKind {
        let raw = sourceID.rawValue
        if raw.hasPrefix("library:") { return .library }
        if raw.hasPrefix("cloud:") { return .cloudMount }
        if raw.hasPrefix("catalog:") { return .catalogSite }
        if raw.hasPrefix("cinema:") { return .cinemaFeed }
        if raw.hasPrefix("tv:") { return .iptv }
        if raw.hasPrefix("disk:") { return .localDisk }
        return .library
    }

    private static func uuid(in sourceID: SourceID, prefix: String) -> UUID? {
        guard sourceID.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(sourceID.rawValue.dropFirst(prefix.count)))
    }
}
