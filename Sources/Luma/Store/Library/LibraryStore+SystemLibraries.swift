import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

extension LibraryStore {
    // MARK: - 图库选择器

    static let recentLibrariesKey = LibraryPaths.recentLibrariesKey

    func presentLibraryPicker() {
        showLibraryPicker = true
    }

    /// 记录用过的图库，供选择器列表使用。
    func rememberLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths.removeLast(paths.count - 10) }
        UserDefaults.standard.set(paths, forKey: Self.recentLibrariesKey)
        // 同时登记到全局图库列表：第一次的那个成为系统默认图库，之后都算挂载图库。
        registerKnownLibrary(url)
    }

    // MARK: - 系统图库列表

    /// 归一化路径：只差尾部斜杠 / 相对写法的同一个图库必须视为同一条记录。
    func isSameSystemLibraryPath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    /// 当前 App 图库本身就是官方「照片」图库时的自身路径；不是这种图库则返回 nil。
    var containerNativeLibraryPath: String? {
        guard let url = LibraryPaths.containerLibraryURL,
              LibraryPaths.isNativeLibrary(url) else { return nil }
        return url.standardizedFileURL.path
    }

    func isContainerNativeLibraryPath(_ path: String) -> Bool {
        guard let selfPath = containerNativeLibraryPath else { return false }
        return isSameSystemLibraryPath(path, selfPath)
    }

    /// 正在浏览的系统图库就是 App 自己的图库（而不是外接的第二个库）。
    var isBrowsingContainerSystemLibrary: Bool {
        guard let path = systemLibraryPath else { return false }
        return isContainerNativeLibraryPath(path)
    }

    /// 绑定关系（打开过的图库 / 已连接的照片图库）只写在**当前图库自己的** SQLite settings 里。
    /// 断开 = 从当前图库的记录里删掉，下次打开这个图库就不会再出现。
    static let connectedLibrariesSettingKey = "system_libraries"
    static let knownLibrariesSettingKey = "known_libraries"

    /// 旧版本把这两份记录放在全局偏好里：只做一次性迁移，迁完立即删除。
    /// 否则断开的图库下次启动又会被旧数据拉回来。
    static let legacyConnectedLibrariesKey = "settings.systemLibraries"
    static let legacyGlobalConnectedLibrariesKey = "settings.systemLibraries.global"
    static let legacyKnownLibrariesKey = LibraryPaths.knownLibrariesKey

    /// 读当前图库自己的记录；当前图库还没有这份记录时，把旧版全局数据迁进来一次。
    func storedBindings(_ settingKey: String,
                                legacyKeys: [String]) -> [SystemLibraryRef]? {
        if let json = metadataStore?.setting(settingKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) {
            return decoded
        }
        for key in legacyKeys {
            // 当前图库没打开时不迁移：没有可写入的库，迁完就丢了。
            guard metadataStore != nil else { return nil }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            return decoded
        }
        return nil
    }

    func persistBindings(_ list: [SystemLibraryRef], settingKey: String) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        // 当前图库没打开（建库 / 打开引导页）时没有可写的库，交给下次打开时重建。
        metadataStore?.setSetting(settingKey, json)
    }

    /// 读取**当前图库**自己的系统图库连接列表；同一时间只有一个处于连接/展开状态。
    func loadSystemLibraries() {
        var list = storedBindings(Self.connectedLibrariesSettingKey,
                                  legacyKeys: [Self.legacyGlobalConnectedLibrariesKey,
                                               Self.legacyConnectedLibrariesKey]) ?? []
        // 列表可保存多个图库，按归一化路径去重。上限放宽到 50。
        var seen: Set<String> = []
        list = list.filter {
            seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted
        }
        if list.count > 50 { list.removeLast(list.count - 50) }
        // 当前图库本身是官方「照片」图库时，它的内容是主侧边栏，不登记成额外连接。
        if let nativeSelfPath = containerNativeLibraryPath {
            list.removeAll { isSameSystemLibraryPath($0.path, nativeSelfPath) }
        }
        if let path = systemLibraryPath,
           !isContainerNativeLibraryPath(path),
           !list.contains(where: { isSameSystemLibraryPath($0.path, path) }) {
            list.insert(SystemLibraryRef(path: path,
                                         name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                        at: 0)
        }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    func persistSystemLibraries(_ list: [SystemLibraryRef]) {
        persistBindings(list, settingKey: Self.connectedLibrariesSettingKey)
    }

    // MARK: - 全部图库（默认 + 挂载）

    /// 所有打开过的图库：第一条是系统默认图库，其余都是挂载图库。
    /// 记录写在当前图库自己的 settings 里：断开即删除，下次打开这个图库不再出现。
    /// - Parameter inheritRecentIfEmpty: 没有打开任何图库（启动引导页）时，允许用「最近打开」兜底，
    ///   让「创建或打开图库」界面能列出历史库；图库内部的调用一律不继承。
    func loadKnownLibraries(inheritRecentIfEmpty: Bool = false) {
        let stored = storedBindings(Self.knownLibrariesSettingKey,
                                    legacyKeys: [Self.legacyKnownLibrariesKey])
        var list = stored ?? []
        // 当前图库还没有这份记录（首次升级）：用「最近打开」恢复一次，之后以图库记录为准。
        // 空白图库不参与迁移：那是刚建的新库，不该继承别的图库的历史。
        let hasContent = !photos.isEmpty || !albums.isEmpty || !folders.isEmpty
        if stored == nil, hasContent || inheritRecentIfEmpty,
           let recent = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) {
            list = recent.reversed().compactMap { path in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return SystemLibraryRef(
                    path: path,
                    name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            }
        }
        var seen: Set<String> = []
        list = list.filter {
            seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted
        }
        // 当前图库必须在列表里：首次升级 / 首次打开时用它兜底。
        if let current = LibraryPaths.containerLibraryURL?.standardizedFileURL.path,
           !list.contains(where: { isSameSystemLibraryPath($0.path, current) }) {
            list.append(SystemLibraryRef(
                path: current,
                name: URL(fileURLWithPath: current).deletingPathExtension().lastPathComponent))
        }
        knownLibraries = list
        // 「默认」= 下次启动会打开的那个库：显式默认优先，否则就是上次打开的库。
        let explicit = UserDefaults.standard.bool(forKey: LibraryPaths.defaultLibraryExplicitKey)
        let saved = UserDefaults.standard.string(forKey: LibraryPaths.defaultLibraryKey)
        if explicit, let saved, list.contains(where: { isSameSystemLibraryPath($0.path, saved) }) {
            defaultLibraryPath = saved
        } else if let last = LibraryPaths.lastOpenedLibraryURL(),
                  list.contains(where: { isSameSystemLibraryPath($0.path, last.path) }) {
            defaultLibraryPath = last.path
        } else {
            defaultLibraryPath = nil
        }
        persistKnownLibraries()
    }

    func persistKnownLibraries() {
        persistBindings(knownLibraries, settingKey: Self.knownLibrariesSettingKey)
    }

    /// 记录一个打开过的图库：首次打开的那个自动成为系统默认图库，之后只追加挂载图库。
    func registerKnownLibrary(_ url: URL) {
        // 首次运行时先从旧记录恢复历史图库，默认图库才不会错认成刚打开的这一个。
        if knownLibraries.isEmpty { loadKnownLibraries() }
        let path = url.standardizedFileURL.path
        if !knownLibraries.contains(where: { isSameSystemLibraryPath($0.path, path) }) {
            knownLibraries.append(SystemLibraryRef(
                path: path,
                name: url.deletingPathExtension().lastPathComponent))
        }
        persistKnownLibraries()
    }

    /// 某个路径是不是启动图库：显式默认优先，其次是上次打开的图库。
    /// 它代表「下次启动会打开哪个库」，界面上的「默认」标记以它为准。
    func isDefaultLibrary(_ path: String) -> Bool {
        guard let url = LibraryPaths.storedDefaultLibrary() ?? LibraryPaths.lastOpenedLibraryURL() else {
            return false
        }
        return isSameSystemLibraryPath(path, url.path)
    }

    /// 是否用户显式设置的默认图库（与「上次打开」区分，用于文案与移除保护）。
    func isExplicitDefaultLibrary(_ path: String) -> Bool {
        guard let url = LibraryPaths.storedDefaultLibrary() else { return false }
        return isSameSystemLibraryPath(path, url.path)
    }

    /// 把某个图库设为默认：下次启动直接打开它，并排到全部图库的第一位。
    /// 这里会点亮「用户显式设置」标记，旧版本自动挑出来的默认值不会改变启动行为。
    func setDefaultLibrary(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              LibraryPaths.isLibraryContainer(url) else {
            showToast("找不到这个图库，可能已被移动或删除")
            return
        }
        let normalized = url.path
        defaultLibraryPath = normalized
        LibraryPaths.setStoredDefaultLibrary(url)
        if let index = knownLibraries.firstIndex(where: { isSameSystemLibraryPath($0.path, normalized) }) {
            let item = knownLibraries.remove(at: index)
            knownLibraries.insert(item, at: 0)
            persistKnownLibraries()
        } else {
            registerKnownLibrary(url)
        }
        let name = url.deletingPathExtension().lastPathComponent
        showToast("「\(name)」已设为默认图库，下次启动直接打开")
    }

    /// 断开一个图库：从「全部图库」、最近打开与默认图库记录里移除。
    /// 如果它正是当前打开的图库，同时释放容器并回到「创建或打开图库」界面；
    /// 磁盘上的图库包与照片一律保留，之后可以重新打开。
    func disconnectLibrary(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let name = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        let isCurrent = LibraryPaths.containerLibraryURL.map {
            isSameSystemLibraryPath($0.path, normalized)
        } ?? false

        removeLibraryBindings(normalized)
        if let active = systemLibraryPath, isSameSystemLibraryPath(active, normalized) {
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }

        if isCurrent {
            releaseCurrentLibraryForDetach()
        }
        loadKnownLibraries()
        showToast("已断开「\(name)」，磁盘上的图库文件仍保留")
    }

    /// 从一个图库里删掉另一个图库的绑定：打开过的列表、已连接的照片图库、最近打开，
    /// 以及默认图库 / 下次启动引导，全部一起清理，避免它从别处再冒出来。
    func removeLibraryBindings(_ normalized: String) {
        knownLibraries.removeAll { isSameSystemLibraryPath($0.path, normalized) }
        if systemLibraries.contains(where: { isSameSystemLibraryPath($0.path, normalized) }) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, normalized) }
            persistSystemLibraries(systemLibraries)
        }
        // 选择器的数据源包含「最近打开」：断开时必须一起清掉，否则它还会出现在选取图库里。
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        recent.removeAll { isSameSystemLibraryPath($0, normalized) }
        UserDefaults.standard.set(recent, forKey: Self.recentLibrariesKey)
        persistKnownLibraries()
        // 默认图库按原始记录判断：库不在磁盘上时 storedDefaultLibrary() 会返回 nil，
        // 只按有效路径判断会漏清理，等外置盘重新插上就又会被当作默认库打开。
        let defaults = UserDefaults.standard
        if defaults.string(forKey: LibraryPaths.defaultLibraryKey)
            .map({ isSameSystemLibraryPath($0, normalized) }) == true {
            defaults.removeObject(forKey: LibraryPaths.defaultLibraryKey)
            defaults.removeObject(forKey: LibraryPaths.defaultLibraryExplicitKey)
        }
        if LibraryPaths.storedLastOpenedPath()
            .map({ isSameSystemLibraryPath($0, normalized) }) == true {
            LibraryPaths.clearBootstrap()
        }
    }

    /// 退出当前图库但保留文件：清空只属于这个图库的内存状态，回到建库 / 打开引导。
    /// 之后新建或打开图库时，`switchLibraryContainer` / `createLibrary` 会重新装载状态。
    func releaseCurrentLibraryForDetach() {
        flushMetadata()
        metadataStore = nil
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        tasks.cancel(.libraryIndex)
        libraryIndexComplete = true
        photos = []
        albums = []
        folders = []
        smartAlbums = []
        pinnedItems = []
        selection.removeAll()
        viewerID = nil
        editorID = nil
        similarScope = nil
        abortHealthScan()
        healthReport = nil
        finishCatalogPlayback()
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        resetFaceClusterState()
        resetBeautyState()
        resetPlaceCaches()
        resetUndoHistory()
        resetHashState()
        resetConfirmationState()
        navigate(to: .library)
        LibraryPaths.detach()
        containerLibraryPath = nil
        needsLibrarySetup = true
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        showNewLibrarySheet = false
    }

    /// 登记系统图库：列表可保存多个，连接新图库时追加或更新，切换只改变当前连接。
    func registerSystemLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        // 自己外接自己：只切换回当前图库，不写进连接列表。
        if isContainerNativeLibraryPath(path) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, path) }
            persistSystemLibraries(systemLibraries)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        var list = systemLibraries
        if let index = list.firstIndex(where: { isSameSystemLibraryPath($0.path, path) }) {
            list[index] = SystemLibraryRef(path: path, name: name)
        } else {
            list.insert(SystemLibraryRef(path: path, name: name), at: 0)
        }
        if list.count > 50 { list.removeLast(list.count - 50) }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    /// 断开某个系统图库；若断开的正是当前库，则退回「图库」。
    func removeSystemLibrary(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let active = systemLibraryPath, isSameSystemLibraryPath(active, normalized) {
            if isSystemScope {
                navigate(to: .library)
            }
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }
        // 同一个库可能同时登记在「打开过的图库」和「最近打开」里：
        // 只删当前这一份的话，断开后它会立刻从另一个列表冒出来。
        removeLibraryBindings(normalized)
        loadKnownLibraries()
    }

}
