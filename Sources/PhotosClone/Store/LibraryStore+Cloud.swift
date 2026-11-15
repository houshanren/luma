import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Network storage (WebDAV)

    /// 切换图库：网盘挂载、目录缓存与云端收藏都属于上一个图库，必须先清空再读新库，
    /// 否则旧挂载会被当成新库的连接写回它的 settings。
    func resetCloudStateForLibrarySwitch() {
        cloudLoadToken += 1
        cloudMounts = []
        cloudFolders = []
        cloudPhotos = []
        cloudPath = ""
        cloudTrail = []
        cloudError = nil
        cloudBusyText = nil
        cloudSheetMount = nil
        cloudVisibleCacheKey = nil
        cloudVisibleCacheValue = []
        cloudDirectoryCache.removeAll()
        cloudPasswords.removeAll()
        cloudFavorites = []
    }

    func loadCloudMounts() {
        guard let json = metadataStore?.setting("cloud_mounts"),
              let data = json.data(using: .utf8),
              let mounts = try? JSONDecoder().decode([CloudMount].self, from: data) else { return }
        cloudMounts = mounts
    }

    func saveCloudMounts() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cloudMounts),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting("cloud_mounts", json)
    }

    /// 启动时静默重连已保存的 SMB；NAS 不在线时忽略，等用户点开时再重试。
    func remountSMBMountsOnLaunch() {
        let mounts = cloudMounts.filter { $0.kind == .smb }
        guard !mounts.isEmpty else { return }
        Task {
            for mount in mounts {
                guard let client = SMBClient(mount: mount,
                                             password: cloudPassword(for: mount.id)) else { continue }
                _ = try? await client.ensureMounted()
            }
        }
    }

    func cloudPassword(for mountID: UUID) -> String {
        if let cached = cloudPasswords[mountID] { return cached }
        let value = CloudCredentials.password(for: mountID)
        cloudPasswords[mountID] = value
        return value
    }

    func cloudMount(for id: UUID?) -> CloudMount? {
        guard let id else { return nil }
        return cloudMounts.first(where: { $0.id == id })
    }

    func presentCloudSheet(_ mount: CloudMount?) {
        cloudSheetMount = mount
        showCloudSheet = true
    }

    func presentCloudWizard(flow: CloudWizardFlow? = nil) {
        cloudSheetMount = nil
        showCloudSheet = false
        cloudWizardInitialFlow = flow
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            showCloudWizard = true
        }
    }

    func probeAList(address: String) async -> (ok: Bool, message: String) {
        await AListProbe.check(address: address)
    }

    func dismissCloudSheet() {
        showCloudSheet = false
        cloudSheetMount = nil
    }

    func testCloudConnection(address: String, username: String,
                             password: String) async -> (ok: Bool, message: String) {
        if CloudKind.detect(from: address) == .smb {
            return await SMBClient.test(address: address, username: username, password: password)
        }
        guard let client = WebDAVClient(baseURLString: address,
                                        username: username,
                                        password: password) else {
            return (false, "服务器地址无效，请填写 http(s)://主机:端口/路径")
        }
        do {
            let entries = try await client.list(path: "")
            let folders = entries.filter { $0.isDirectory }.count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            return (true, "连接成功：\(folders) 个文件夹、\(media) 个媒体文件")
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveCloudMount(existing: CloudMount?, name: String, address: String,
                        username: String, password: String,
                        kind requestedKind: CloudKind = .webdav) -> String? {
        let kind = existing?.kind ?? CloudKind.detect(from: address) ?? requestedKind
        let normalized: String
        let host: String?
        switch kind {
        case .smb:
            guard let value = SMBClient.normalizedAddress(address) else {
                return "SMB 地址无效，请填写 smb://主机/共享名，例如 smb://192.168.1.10/photo"
            }
            normalized = value
            host = URLComponents(string: value)?.host
        default:
            guard let base = WebDAVClient.normalizedBaseURL(address) else {
                return "服务器地址无效，请填写 http(s)://主机:端口/路径"
            }
            normalized = base.absoluteString
            host = base.host
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = kind == .smb
            ? (SMBClient.displayName(address) ?? "SMB 共享")
            : (host ?? "网络存储")
        let finalName = trimmedName.isEmpty ? fallbackName : trimmedName

        if var mount = existing, let index = cloudMounts.firstIndex(where: { $0.id == mount.id }) {
            let previousAddress = mount.baseURL
            mount.name = finalName
            mount.baseURL = normalized
            mount.username = username
            cloudMounts[index] = mount
            if !password.isEmpty {
                CloudCredentials.setPassword(password, for: mount.id)
                cloudPasswords[mount.id] = password
            }
            if mount.kind == .smb, previousAddress != normalized {
                SMBClient.unmount(address: previousAddress)
            }
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(mount.id.uuidString) }
            saveCloudMounts()
            if case .cloudMount(let current) = sidebarItem, current == mount.id {
                loadCloudDirectory(mountID: mount.id, path: cloudPath, force: true)
            }
            showToast("已更新「\(finalName)」")
            return nil
        }

        let mount = CloudMount(kind: kind, name: finalName,
                               baseURL: normalized, username: username,
                               scanAll: kind == .smb)
        cloudMounts.append(mount)
        CloudCredentials.setPassword(password, for: mount.id)
        cloudPasswords[mount.id] = password
        saveCloudMounts()
        showToast("已添加「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    func removeCloudMount(_ id: UUID) {
        if let mount = cloudMounts.first(where: { $0.id == id }), mount.kind == .smb {
            SMBClient.unmount(address: mount.baseURL)
        }
        cloudMounts.removeAll { $0.id == id }
        CloudCredentials.delete(for: id)
        CloudOAuthStore.deleteToken(mountID: id)
        cloudPasswords[id] = nil
        // 清掉该挂载的本地收藏记录，避免残留键越积越多。
        let favoritePrefix = "\(id.uuidString)|"
        if cloudFavorites.contains(where: { $0.hasPrefix(favoritePrefix) }) {
            cloudFavorites = cloudFavorites.filter { !$0.hasPrefix(favoritePrefix) }
            persistCloudFavorites()
        }
        cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(id.uuidString) }
        try? FileManager.default.removeItem(at: LibraryPaths.cloudThumbs.appendingPathComponent(id.uuidString,
                                                                                            isDirectory: true))
        if case .cloudMount(let current) = sidebarItem, current == id {
            navigate(to: .library)
        }
        saveCloudMounts()
        showToast("已断开网络存储")
    }

    func openCloudMount(_ id: UUID) {
        guard let mount = cloudMounts.first(where: { $0.id == id }) else { return }
        switch mount.kind {
        case .webdav:
            openBrowseMount(mount)
        case .smb:
            if mount.scanAll {
                cloudPath = ""
                cloudTrail = [CloudCrumb(id: "", name: mount.name)]
                loadCloudTree(mountID: id, rootPath: "", force: true)
            } else {
                openBrowseMount(mount)
            }
        case .aliyun:
            cloudTrail = [CloudCrumb(id: "", name: mount.name)]
            loadCloudDirectory(mountID: id, path: "", force: true)
        case .baidu:
            cloudTrail = [CloudCrumb(id: "/", name: mount.name)]
            loadCloudDirectory(mountID: id, path: "/", force: true)
        }
    }

    func openBrowseMount(_ mount: CloudMount) {
        let path = mount.lastPath
        var trail = [CloudCrumb(id: "", name: mount.name)]
        var accumulated: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            accumulated.append(component)
            trail.append(CloudCrumb(id: accumulated.joined(separator: "/"), name: component))
        }
        cloudTrail = trail
        loadCloudDirectory(mountID: mount.id, path: path)
    }

    /// 切换 SMB 的「整个共享 / 文件夹」浏览方式。
    func setCloudScanAll(_ enabled: Bool) {
        guard case .cloudMount(let id) = sidebarItem,
              let index = cloudMounts.firstIndex(where: { $0.id == id }),
              cloudMounts[index].kind == .smb,
              cloudMounts[index].scanAll != enabled else { return }
        cloudMounts[index].scanAll = enabled
        saveCloudMounts()
        if enabled {
            cloudPath = ""
            cloudTrail = [CloudCrumb(id: "", name: cloudMounts[index].name)]
            loadCloudTree(mountID: id, rootPath: "", force: true)
        } else {
            openCloudMount(id)
        }
    }

    func refreshCloudDirectory() {
        guard case .cloudMount(let id) = sidebarItem else { return }
        if isCurrentCloudScanAll {
            loadCloudTree(mountID: id, rootPath: cloudPath, force: true)
            return
        }
        loadCloudDirectory(mountID: id, path: cloudPath, force: true)
    }

    func cloudGoUp() {
        guard case .cloudMount(let id) = sidebarItem, cloudTrail.count > 1 else { return }
        cloudTrail.removeLast()
        guard let parent = cloudTrail.last else { return }
        loadCloudDirectory(mountID: id, path: parent.id)
    }

    func enterCloudFolder(_ entry: CloudEntry) {
        guard case .cloudMount(let id) = sidebarItem else { return }
        cloudTrail.append(CloudCrumb(id: entry.path, name: entry.name))
        loadCloudDirectory(mountID: id, path: entry.path)
    }

    func loadCloudDirectory(mountID: UUID, path: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = path
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken

        let cacheKey = "\(mountID.uuidString)|\(path)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = cached.folders
            cloudPhotos = cached.photos
            cloudLoading = false
            return
        }

        cloudLoading = true
        cloudBusyText = nil
        cloudFolders = []
        cloudPhotos = []

        Task {
            do {
                let entries = try await CloudService.list(mount: mount, containerID: path)
                guard token == self.cloudLoadToken else { return }

                let folders = entries
                    .filter { $0.isDirectory }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let photos = entries
                    .filter { !$0.isDirectory && $0.isMedia }
                    .map { self.makeCloudPhoto(mount: mount, entry: $0) }
                    .sorted { $0.capturedAt > $1.capturedAt }

                self.cloudFolders = folders
                self.cloudPhotos = photos
                self.cloudDirectoryCache[cacheKey] = (folders, photos)
                self.cloudLoading = false
                self.cloudError = nil

                if mount.kind == .webdav || mount.kind == .smb,
                   let index = self.cloudMounts.firstIndex(where: { $0.id == mountID }),
                   self.cloudMounts[index].lastPath != path {
                    self.cloudMounts[index].lastPath = path
                    self.saveCloudMounts()
                }
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// 递归扫描 SMB 共享，把所有媒体汇总成一个列表（不受当前文件夹限制）。
    func loadCloudTree(mountID: UUID, rootPath: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = rootPath
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken

        let cacheKey = "\(mountID.uuidString)|tree|\(rootPath)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = []
            cloudPhotos = cached.photos
            cloudLoading = false
            cloudBusyText = nil
            return
        }

        cloudLoading = true
        cloudFolders = []
        cloudPhotos = []
        cloudBusyText = "正在扫描整个共享…"

        Task {
            do {
                let entries = try await CloudService.scanTree(mount: mount, path: rootPath)
                guard token == self.cloudLoadToken else { return }
                let photos = entries
                    .map { self.makeCloudPhoto(mount: mount, entry: $0) }
                    .sorted { $0.capturedAt > $1.capturedAt }
                self.cloudFolders = []
                self.cloudPhotos = photos
                self.cloudDirectoryCache[cacheKey] = ([], photos)
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = nil
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.showToast(error.localizedDescription)
            }
        }
    }

    func makeCloudPhoto(mount: CloudMount, entry: CloudEntry) -> PhotoItem {
        var item = PhotoItem(
            id: CloudIdentity.id(mountID: mount.id, path: entry.path),
            filename: entry.name,
            editedFilename: nil,
            originalName: entry.name,
            capturedAt: entry.modifiedAt ?? Date.distantPast,
            pixelWidth: entry.pixelWidth ?? 0,
            pixelHeight: entry.pixelHeight ?? 0,
            fileSize: entry.size,
            kind: entry.isVideo ? .video : .photo
        )
        item.source = .cloud
        item.cloudMountID = mount.id
        item.cloudPath = entry.path
        item.cloudRemoteID = entry.remoteID
        item.cloudThumbnailURL = entry.thumbnailURL
        item.duration = entry.duration
        item.isFavorite = cloudFavorites.contains(Self.cloudFavoriteKey(mountID: mount.id, path: entry.path))
        return item
    }

    // MARK: - 云照片的本地收藏（不写回网盘）

    static func cloudFavoriteKey(mountID: UUID, path: String) -> String {
        "\(mountID.uuidString)|\(path)"
    }

    func loadCloudFavorites() {
        guard let json = metadataStore?.setting(Self.cloudFavoritesSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            cloudFavorites = []
            return
        }
        cloudFavorites = Set(list)
    }

    /// 收藏 / 取消收藏云照片：仅更新本地记录与当前列表，不修改 NAS 或网盘上的文件。
    func setCloudFavorite(_ favorite: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var list = cloudPhotos
        var changed = false
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            if favorite {
                if cloudFavorites.insert(key).inserted { changed = true }
            } else if cloudFavorites.remove(key) != nil {
                changed = true
            }
            list[index].isFavorite = favorite
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudFavorites()
        cloudVisibleCacheKey = nil
        showToast(favorite ? "已收藏（仅本机记录）" : "已取消收藏")
    }

    func persistCloudFavorites() {
        guard let data = try? JSONEncoder().encode(Array(cloudFavorites)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudFavoritesSettingKey, json)
    }

    /// 旧版网盘收藏存在全局 UserDefaults，仅用于一次性迁入当前图库。
    static let cloudFavoritesDefaultsKey = "cloud.favorites.v1"
    /// 当前图库自己的网盘收藏（写在该图库的 SQLite settings 表）。
    static let cloudFavoritesSettingKey = "cloud_favorites"

    func applyCloudPixelSize(photoID: UUID, size: CGSize) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        let width = Int(size.width)
        let height = Int(size.height)
        guard cloudPhotos[index].pixelWidth != width || cloudPhotos[index].pixelHeight != height else { return }
        cloudPhotos[index].pixelWidth = width
        cloudPhotos[index].pixelHeight = height
        updateCachedCloudPhoto(cloudPhotos[index])
    }

    func applyCloudDuration(photoID: UUID, duration: Double) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        guard cloudPhotos[index].duration != duration else { return }
        cloudPhotos[index].duration = duration
        updateCachedCloudPhoto(cloudPhotos[index])
    }

    func updateCachedCloudPhoto(_ photo: PhotoItem) {
        for key in cloudDirectoryCache.keys {
            guard var entry = cloudDirectoryCache[key],
                  let index = entry.photos.firstIndex(where: { $0.id == photo.id }) else { continue }
            entry.photos[index] = photo
            cloudDirectoryCache[key] = entry
        }
    }

    /// 按需加载：优先使用服务端缩略图；WebDAV 走 EXIF 区间探测，避免整目录原图下行。
    func cloudThumbnail(for photo: PhotoItem) async -> NSImage? {
        if let cached = ImageLoader.cachedCloudThumbnail(for: photo) {
            return cached
        }
        if let remote = photo.cloudThumbnailURL, !remote.isEmpty,
           let image = await CloudImageFetcher.thumbnail(for: photo, urlString: remote) {
            ImageLoader.cacheCloudThumbnail(image, for: photo)
            return image
        }
        guard let mount = cloudMount(for: photo.cloudMountID),
              mount.kind == .webdav || mount.kind == .smb else { return nil }
        let result = await CloudThumbnailLoader.shared.thumbnail(for: photo,
                                                                 mount: mount,
                                                                 password: cloudPassword(for: mount.id))
        if let size = result.size, size.width > 0, size.height > 0 {
            applyCloudPixelSize(photoID: photo.id, size: size)
        }
        if let duration = result.duration, duration > 0 {
            applyCloudDuration(photoID: photo.id, duration: duration)
        }
        guard let image = result.image else { return nil }
        ImageLoader.cacheCloudThumbnail(image, for: photo)
        return image
    }

    func cloudDisplayImage(for photo: PhotoItem) async -> NSImage? {
        guard let mount = cloudMount(for: photo.cloudMountID) else { return nil }
        if let cached = ImageLoader.cachedCloudFullImage(for: photo) {
            return cached
        }
        if mount.kind == .smb, let client = SMBClient(mount: mount,
                                                       password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: photo.cloudPath ?? "") else { return nil }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.fullImage(from: url, maxPixel: 6000)
            }.value
            if let loaded { ImageLoader.cacheCloudFullImage(loaded, for: photo) }
            return loaded
        }
        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            return await ImageLoader.cloudFullImage(for: photo, client: client)
        }
        guard let resource = await cloudStream(for: photo),
              let image = await CloudImageFetcher.fullImage(photo: photo, resource: resource) else {
            return nil
        }
        ImageLoader.cacheCloudFullImage(image, for: photo)
        return image
    }

    func cloudStream(for photo: PhotoItem) async -> CloudStreamResource? {
        guard let mount = cloudMount(for: photo.cloudMountID) else { return nil }
        return try? await CloudService.stream(mount: mount, photo: photo)
    }

    func downloadCloudItem(_ photo: PhotoItem, to url: URL) async throws {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            throw CloudOAuthError.api("挂载不存在")
        }
        if mount.kind == .smb,
           let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)),
           let path = photo.cloudPath {
            _ = try await client.ensureMounted()
            guard let source = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 挂载点不可用，请检查共享是否已连接")
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            try fm.copyItem(at: source, to: url)
            return
        }
        if mount.kind == .webdav,
           let client = CloudService.webdavClient(mount),
           let path = photo.cloudPath {
            try await client.download(path: path, to: url)
            return
        }
        let resource = try await CloudService.stream(mount: mount, photo: photo)
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudOAuthError.api("下载失败")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.moveItem(at: temp, to: url)
    }

    // MARK: - 云端写操作

    /// 授权完成后注册一个官方网盘挂载点。
    @discardableResult
    func registerOAuthMount(kind: CloudKind, name: String,
                            driveID: String?, token: CloudToken) -> String? {
        guard kind.usesOAuth else { return "不支持的接入方式" }
        if let existing = cloudMounts.first(where: { $0.kind == kind && $0.remoteDriveID == driveID }) {
            CloudOAuthStore.saveToken(token, mountID: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            navigate(to: .cloudMount(existing.id))
            showToast("已更新「\(existing.name)」的授权")
            return nil
        }
        let mount = CloudMount(kind: kind, name: name, remoteDriveID: driveID)
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(name)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    func cloudClient(for mountID: UUID) -> WebDAVClient? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return nil }
        return WebDAVClient(baseURLString: mount.baseURL,
                            username: mount.username,
                            password: cloudPassword(for: mount.id))
    }

    func requestCloudRename(_ photoID: UUID) {
        guard isCurrentCloudWritable else { return }
        guard let photo = anyPhoto(id: photoID), photo.isCloud else { return }
        cloudNameRequest = CloudNameRequest(mode: .rename(photoID: photoID, current: photo.originalName))
    }

    func requestCloudNewFolder() {
        guard isCurrentCloudWritable else { return }
        cloudNameRequest = CloudNameRequest(mode: .newFolder)
    }

    func commitCloudName(_ request: CloudNameRequest, text: String) {
        guard isCurrentCloudWritable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.replacingOccurrences(of: "/", with: "_")
        guard !name.isEmpty else { return }
        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        cloudNameRequest = nil

        switch request.mode {
        case .newFolder:
            let target = cloudPath.isEmpty ? name : cloudPath + "/" + name
            Task {
                do {
                    try await client.createFolder(path: target)
                    showToast("已新建文件夹「\(name)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("新建失败：\(error.localizedDescription)")
                }
            }
        case .rename(let photoID, _):
            guard let photo = anyPhoto(id: photoID), let oldPath = photo.cloudPath else { return }
            var components = oldPath.split(separator: "/").map(String.init)
            components.removeLast()
            let oldExtension = (photo.originalName as NSString).pathExtension
            let typedExtension = (name as NSString).pathExtension
            let finalName: String
            if !oldExtension.isEmpty,
               typedExtension.lowercased() != oldExtension.lowercased() {
                finalName = name + "." + oldExtension
            } else {
                finalName = name
            }
            let newPath = (components + [finalName]).joined(separator: "/")
            guard newPath != oldPath else { return }
            Task {
                do {
                    try await client.move(from: oldPath, to: newPath)
                    selection.removeAll()
                    if viewerID == photoID {
                        viewerID = nil
                    }
                    showToast("已重命名为「\(finalName)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("重命名失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func confirmDeleteCloud(_ ids: Set<UUID>) {
        guard isCurrentCloudWritable else {
            if case .cloudMount(let id) = sidebarItem, cloudMount(for: id)?.kind == .smb {
                showToast("SMB 共享为只读，删除请到 NAS 上操作")
            } else {
                showToast("官方网盘接入当前为只读，删除请到网盘 App")
            }
            return
        }
        let items = ids.compactMap { anyPhoto(id: $0) }.filter { $0.isCloud }
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? "从云端删除「\(items[0].originalName)」？"
            : "从云端删除 \(items.count) 项？"
        alert.informativeText = "文件会直接从 WebDAV 服务器删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        Task {
            var failed = 0
            for item in items {
                guard let path = item.cloudPath else { continue }
                do {
                    try await client.delete(path: path)
                } catch {
                    failed += 1
                }
            }
            if let viewerID, ids.contains(viewerID) {
                self.viewerID = nil
            }
            selection.removeAll()
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已从云端删除 \(items.count) 项"
                      : "已删除 \(items.count - failed) 项，\(failed) 项失败")
        }
    }

    func presentCloudUploadPanel() {
        guard isCurrentCloudWritable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "上传"
        panel.message = "选择要上传到当前云端目录的照片或视频"
        if panel.runModal() == .OK {
            uploadToCloud(panel.urls)
        }
    }

    func uploadToCloud(_ urls: [URL]) {
        guard isCurrentCloudWritable else { return }
        guard !urls.isEmpty, case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        let basePath = cloudPath
        Task {
            var uploaded = 0
            var failed = 0
            for (index, url) in urls.enumerated() {
                cloudBusyText = "上传 \(index + 1)/\(urls.count)"
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = basePath.isEmpty
                    ? url.lastPathComponent
                    : basePath + "/" + url.lastPathComponent
                do {
                    try await client.upload(path: target, from: url)
                    uploaded += 1
                } catch {
                    failed += 1
                }
            }
            cloudBusyText = nil
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已上传 \(uploaded) 项"
                      : "已上传 \(uploaded) 项，\(failed) 项失败")
        }
    }
}
