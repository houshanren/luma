import Foundation
import LumaContentCore

/// 把现有图库 / 链接图库 / 云盘 / 资源 / 影院适配成统一源目录。
/// 这里只做“描述”，不替换现有导航与播放；后续 Feature 再逐步改为读 SourceDescriptor。
extension LibraryStore {
    /// 当前应用的源目录快照。链接图库与当前图库同为 library kind，
    /// 云盘 / 资源 / 影院是只读浏览源；电视与本地磁盘在接入后追加，当前为空。
    var sourceRegistryState: SourceRegistryState {
        var sources: [SourceDescriptor] = []

        let activeLibraryPath = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .standardizedFileURL.path
        let activeLibraryID = SourceID.library(activeLibraryPath)
        let activeLibraryName = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .deletingPathExtension()
            .lastPathComponent
        sources.append(
            SourceDescriptor(
                id: activeLibraryID,
                kind: .library,
                name: activeLibraryName.isEmpty ? "当前图库" : activeLibraryName,
                subtitle: isNativeContainer ? "当前图库 · 原生" : "当前图库 · 拾光",
                activation: .replaceLibrarySession,
                content: .library,
                write: isNativeContainer ? .nativeLibrary : .managedLibrary,
                sortIndex: 0,
                lastOpenedAt: Date()
            )
        )

        for (index, ref) in systemLibraries.enumerated() {
            sources.append(
                SourceDescriptor(
                    id: SourceID.linkedLibrary(ref.path),
                    kind: .library,
                    name: ref.name,
                    subtitle: "链接图库 · 点击切换",
                    activation: .replaceLibrarySession,
                    content: .library,
                    write: .readOnly,
                    sortIndex: 10 + index
                )
            )
        }

        for (index, mount) in cloudMounts.enumerated() {
            sources.append(
                SourceDescriptor(
                    id: SourceID.cloud(mount.id),
                    kind: .cloudMount,
                    name: mount.name,
                    subtitle: mount.kind.title,
                    activation: .browseReadOnly,
                    content: .cloud,
                    write: .readOnly,
                    sortIndex: 100 + index
                )
            )
        }

        for (index, source) in catalogModel.sources.enumerated() {
            sources.append(
                SourceDescriptor(
                    id: SourceID.catalog(source.id),
                    kind: .catalogSite,
                    name: source.name,
                    subtitle: source.kind.title,
                    activation: .browseReadOnly,
                    content: .catalog,
                    write: .readOnly,
                    isEnabled: source.isEnabled,
                    sortIndex: 200 + index
                )
            )
        }

        if !cinemaEntries(for: .local).isEmpty {
            sources.append(
                SourceDescriptor(
                    id: .localCinema,
                    kind: .cinemaFeed,
                    name: "本地影院",
                    subtitle: "本地视频 · 刮削",
                    activation: .browseReadOnly,
                    content: .cinema,
                    write: .readOnly,
                    sortIndex: 300
                )
            )
        }

        for (index, mount) in cloudMounts.enumerated()
        where !cinemaEntries(for: .mount(mount.id)).isEmpty {
            sources.append(
                SourceDescriptor(
                    id: .mountCinema(mount.id),
                    kind: .cinemaFeed,
                    name: "\(mount.name) · 影院",
                    subtitle: "网盘视频 · 刮削",
                    activation: .browseReadOnly,
                    content: .cinema,
                    write: .readOnly,
                    sortIndex: 310 + index
                )
            )
        }

        return SourceRegistryState(
            sources: sources,
            activeLibraryID: activeLibraryID,
            activeBrowseSourceID: activeBrowseSourceID
        )
    }

    /// 当前右侧正在浏览的源；图库内的相簿 / 相片仍归当前图库。
    private var activeBrowseSourceID: SourceID? {
        switch sidebarItem {
        case .cloudMount(let id):
            return .cloud(id)
        case .catalogSource(let id):
            return .catalog(id)
        case .cinema:
            return .localCinema
        case .cloudCinema(let id):
            return .mountCinema(id)
        default:
            guard let container = LibraryPaths.containerLibraryURL else {
                return .library(LibraryPaths.root.standardizedFileURL.path)
            }
            return .library(container.standardizedFileURL.path)
        }
    }

    // MARK: - 只读内容仓库

    /// 网盘只读仓库：供未来的电视 / 影院通用列表或调试面板直接读取目录，
    /// 不要求先把目录加载进 `CloudBrowserModel`。
    func cloudContentRepository(for mountID: UUID) -> CloudContentRepository? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return nil }
        return CloudContentRepository(mount: mount, rootPath: cloudRootPath(for: mount))
    }

    /// 网络资源只读仓库：直接复用站点适配器，不经过频道页的页面状态。
    func catalogContentRepository(for sourceID: UUID) -> CatalogContentRepository? {
        guard let source = catalogModel.sources.first(where: { $0.id == sourceID }) else { return nil }
        return CatalogContentRepository(source: source)
    }
}
