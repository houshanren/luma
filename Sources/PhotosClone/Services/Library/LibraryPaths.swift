import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

enum LibraryPaths {
    static let applicationRoot: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhotosClone", isDirectory: true)

    private static let bootstrapFile = applicationRoot.appendingPathComponent("ContainerPath.txt")

    private(set) static var containerLibraryURL: URL?
    private(set) static var root: URL = applicationRoot

    static var databaseDir: URL { root.appendingPathComponent("database", isDirectory: true) }
    static var originals: URL { root.appendingPathComponent("originals", isDirectory: true) }
    static var derivatives: URL { root.appendingPathComponent("resources/derivatives", isDirectory: true) }
    static var edited: URL { root.appendingPathComponent("resources/renders", isDirectory: true) }
    static var transcodes: URL { root.appendingPathComponent("resources/transcodes", isDirectory: true) }
    static var backups: URL { root.appendingPathComponent("resources/backups", isDirectory: true) }
    static var cloud: URL { root.appendingPathComponent("cloud", isDirectory: true) }
    static var cloudThumbs: URL { cloud.appendingPathComponent("thumbs", isDirectory: true) }
    /// 系统图库缩略图缓存：同样放本机，避免为每个格子往图库所在（可能很慢的）磁盘写文件。
    /// 官方 derivative 仍然直接复用，这里只存按格子尺寸生成的小图。
    static var systemThumbs: URL {
        applicationRoot.appendingPathComponent("resources/system-thumbs", isDirectory: true)
    }
    /// 官方「照片」图库自己生成好的 derivative 目录（缩略图与视频封面帧）。
    /// 直接复用这些 JPEG，可以避免为每个格子解码 HEIC / RAW / 视频原文件。
    static func systemDerivatives(libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent("resources/derivatives", isDirectory: true)
    }

    /// 官方 derivative 的路径规则：`resources/derivatives/<UUID 首字符>/<UUID>_1_105_c.jpeg`。
    /// 视频没有 `_1_105_c`，官方只保留一张 `_1_102_o.jpeg` 封面帧。
    /// 共享相簿（scopes/cloudsharing）的项目不在库根 derivatives 下：
    /// 图片只有一张 500px 级别的 `_4_5005_c`，视频优先用本机已缓存的 `poster.JPG`。
    static func systemDerivativePath(libraryURL: URL, assetID: UUID, isVideo: Bool,
                                     directory: String? = nil) -> String {
        let key = assetID.uuidString
        if let directory, directory.contains("/") {
            let scoped = libraryURL.appendingPathComponent("scopes/cloudsharing", isDirectory: true)
            if isVideo {
                let poster = scoped.appendingPathComponent("data/\(directory)/\(key).poster.JPG")
                if FileManager.default.fileExists(atPath: poster.path) {
                    return poster.path
                }
            }
            return scoped
                .appendingPathComponent("resources/derivatives/masters", isDirectory: true)
                .appendingPathComponent(String(key.prefix(1)), isDirectory: true)
                .appendingPathComponent("\(key)_4_5005_c.jpeg")
                .path
        }
        let directory = systemDerivatives(libraryURL: libraryURL)
            .appendingPathComponent(String(key.prefix(1)), isDirectory: true)
        let name = isVideo ? "\(key)_1_102_o.jpeg" : "\(key)_1_105_c.jpeg"
        return directory.appendingPathComponent(name).path
    }
    /// 系统「照片」图库的扫描结果缓存（仅索引与元数据，不含原图），同样写进当前图库。
    static var systemLibraryCacheDir: URL {
        root.appendingPathComponent("resources/system-cache", isDirectory: true)
    }

    /// 索引库固定写在本机应用目录，而不是图库所在磁盘：
    /// 系统图库常在外置盘上，边读几十 GB 的 Photos.sqlite 边把索引写回同一块盘，
    /// 会退化成随机读写，构建和翻页都会慢到不可用。
    static var systemIndexCacheDir: URL {
        applicationRoot.appendingPathComponent("resources/system-index", isDirectory: true)
    }

    /// 系统图库的只读索引库：百万级图库不再把整库装进内存，网格与计数按窗口查询它。
    /// 按系统图库路径哈希命名，同一 App 图库可缓存多个系统图库的索引。
    static func systemIndexFile(for libraryURL: URL) -> URL? {
        guard root != applicationRoot || containerLibraryURL != nil else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return systemIndexCacheDir
            .appendingPathComponent("SystemIndex-\(String(hash, radix: 16)).sqlite")
    }
    static var metadataFile: URL { databaseDir.appendingPathComponent("PhotosClone.sqlite") }
    static var libraryFile: URL { applicationRoot.appendingPathComponent("Library.json") }

    /// 拾光写进某个图库容器的旁挂数据：叠加元数据库、索引 / 快照缓存、缩略图与转码缓存。
    /// 刻意不包含 Apple 自己的 `Photos.sqlite`、`originals`、`resources/derivatives`、`resources/renders`。
    static func sidecarArtifacts(in library: URL) -> [URL] {
        let database = library.appendingPathComponent("database", isDirectory: true)
        let resources = library.appendingPathComponent("resources", isDirectory: true)
        return [
            database.appendingPathComponent("PhotosClone.sqlite"),
            database.appendingPathComponent("PhotosClone.sqlite-wal"),
            database.appendingPathComponent("PhotosClone.sqlite-shm"),
            resources.appendingPathComponent("system-cache", isDirectory: true),
            resources.appendingPathComponent("system-thumbs", isDirectory: true),
            resources.appendingPathComponent("transcodes", isDirectory: true),
            resources.appendingPathComponent("backups", isDirectory: true),
            library.appendingPathComponent("cloud", isDirectory: true),
            legacySidecarPath(for: library)
        ]
    }

    private static var legacyOriginals: URL { applicationRoot.appendingPathComponent("Originals", isDirectory: true) }
    private static var legacyThumbs: URL { applicationRoot.appendingPathComponent("Thumbnails", isDirectory: true) }
    private static var legacyEdited: URL { applicationRoot.appendingPathComponent("Edited", isDirectory: true) }

    /// 图库数据统一写在 `.photoslibrary` 包内第一层（database / originals / resources / cloud），
    /// 自建库与官方「照片」图库都用同一套结构；官方库的 `Photos.sqlite` 与 Apple 自带的原图只读，不去改动。
    /// 旧版（lijialong 包标识时期）的旁挂目录名，仅为升级迁移保留，不能改动。
    private static let legacySidecarSubdirectory = "com.lijialong.photosclone"

    /// 旧版把数据放在 `private/com.lijialong.photosclone/`，升级后上移到包内第一层。
    static func legacySidecarPath(for library: URL) -> URL {
        library.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(legacySidecarSubdirectory, isDirectory: true)
    }

    /// 旧版数据上移到包内第一层（幂等，只移动一次）。
    static func migrateSidecarToLibraryRootIfNeeded(at library: URL) {
        let fm = FileManager.default
        let legacy = legacySidecarPath(for: library)
        guard fm.fileExists(atPath: legacy.path) else { return }
        prepareLibraryStructure(at: library)
        // 数据库单独处理：绝不能把旧库的 -wal / -shm 搬进当前库目录，
        // 否则 SQLite 会把别的库的日志当成当前库的日志回放，直接覆盖掉现有数据。
        migrateLegacyDatabase(from: legacy.appendingPathComponent("database", isDirectory: true),
                              to: library.appendingPathComponent("database", isDirectory: true))
        for name in ["originals", "resources", "cloud"] {
            let source = legacy.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            mergeDirectory(source, into: library.appendingPathComponent(name, isDirectory: true))
        }
        if pruneEmptyDirectories(legacy) {
            pruneEmptyDirectories(library.appendingPathComponent("private", isDirectory: true))
        }
    }

    /// 旧库数据库迁移：只有目标库还没有 `PhotosClone.sqlite` 时才搬；
    /// 先把旧库的三件套复制到临时目录、让 SQLite 自己合并 WAL，再只把主文件搬过去。
    private static func migrateLegacyDatabase(from sourceDir: URL, to destinationDir: URL) {
        let fm = FileManager.default
        let source = sourceDir.appendingPathComponent("PhotosClone.sqlite")
        let destination = destinationDir.appendingPathComponent("PhotosClone.sqlite")
        guard fm.fileExists(atPath: source.path),
              !fm.fileExists(atPath: destination.path) else { return }

        let temp = fm.temporaryDirectory.appendingPathComponent("LumaLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let staged = temp.appendingPathComponent("PhotosClone.sqlite")
        guard (try? fm.copyItem(at: source, to: staged)) != nil else { return }
        for suffix in ["-wal", "-shm"] {
            let file = sourceDir.appendingPathComponent("PhotosClone.sqlite" + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            try? fm.copyItem(at: file, to: temp.appendingPathComponent("PhotosClone.sqlite" + suffix))
        }
        // 在临时目录里打开一次，把旧库 WAL 里的已提交内容合并进主文件。
        if let db = try? SQLiteDatabase(path: staged.path, readonly: false) {
            _ = try? db.query("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        guard !fm.fileExists(atPath: destination.path) else { return }
        try? fm.moveItem(at: staged, to: destination)
    }

    /// 自底向上删除空目录；返回该目录最终是否已被删除。
    @discardableResult
    private static func pruneEmptyDirectories(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return false }
        for entry in entries {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                pruneEmptyDirectories(entry)
            }
        }
        let remaining = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        guard remaining.isEmpty else { return false }
        try? fm.removeItem(at: url)
        return true
    }

    /// 递归合并目录：目标不存在则移动，存在则继续向下合并；同名文件以目标为准。
    private static func mergeDirectory(_ source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: source,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                mergeDirectory(entry, into: target)
            } else if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: entry, to: target)
            }
        }
    }

    static func isOfficialLibrary(_ url: URL) -> Bool {
        isNativeLibrary(url)
    }

    /// 由官方「照片」创建的原生图库：带 Apple 的 Photos.sqlite。
    /// 结论不会在运行期变化，缓存起来：外置盘上一次 lstat 可能阻塞几秒，
    /// 而 SwiftUI body / 查询会高频访问这里，不能每次都碰磁盘。
    static func isNativeLibrary(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "photoslibrary" else { return false }
        let key = url.standardizedFileURL.path
        nativeLock.lock()
        if let cached = nativeCache[key] {
            nativeLock.unlock()
            return cached
        }
        nativeLock.unlock()
        let value = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("database/Photos.sqlite").path)
        nativeLock.lock()
        nativeCache[key] = value
        nativeLock.unlock()
        return value
    }

    private static let nativeLock = NSLock()
    private static var nativeCache: [String: Bool] = [:]

    /// 任何 .photoslibrary 包（原生库或本 App 创建的库）都可作为容器。
    static func isLibraryContainer(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "photoslibrary" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 创建与官方同款的 .photoslibrary 包结构，并建立旁挂元数据目录。
    static func createLibrary(at library: URL) -> Bool {
        guard library.pathExtension.lowercased() == "photoslibrary" else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: library.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: library.path)) ?? []
            guard contents.isEmpty else { return false }
        }
        prepareLibraryStructure(at: library)
        return fm.fileExists(atPath: library.appendingPathComponent("database").path)
    }

    /// 读取启动配置：如果用户已经选择了 .photoslibrary，本地媒体与元数据都放进库内旁挂目录。
    /// 没有图库时不再在固定位置自动建库，只保留旧的本地库数据等待用户迁入新图库。
    static func configure() {
        let stored = readBootstrap()
        var library: URL?
        if let stored, stored != "local" {
            library = URL(fileURLWithPath: stored)
        } else if stored == nil, let legacy = readLegacySystemLibraryPath() {
            library = URL(fileURLWithPath: legacy)
        }

        if let library, isLibraryContainer(library) {
            containerLibraryURL = library
            root = library
            migrateSidecarToLibraryRootIfNeeded(at: library)
            prepare()
            migrateLegacyLayoutIfNeeded()
            writeBootstrap(library.path)
        } else {
            containerLibraryURL = nil
            root = applicationRoot
            if hasLocalLibraryData {
                prepare()
                migrateLegacyLayoutIfNeeded()
            }
        }
    }

    /// 尚未选择任何图库，启动后必须先新建或打开一个图库。
    static var requiresLibrarySetup: Bool { containerLibraryURL == nil }

    /// Application Support 里是否还残留旧版（没有图库包）的本地库数据。
    static var hasLocalLibraryData: Bool {
        let fm = FileManager.default
        let candidates = [
            applicationRoot.appendingPathComponent("database/PhotosClone.sqlite").path,
            applicationRoot.appendingPathComponent("PhotosClone.sqlite").path,
            applicationRoot.appendingPathComponent("originals").path,
            applicationRoot.appendingPathComponent("Originals").path
        ]
        return candidates.contains { fm.fileExists(atPath: $0) }
    }

    static func prepare() {
        for dir in [root, databaseDir, originals, derivatives, edited, transcodes, backups,
                    cloudThumbs, systemThumbs, systemLibraryCacheDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func thumbnailURL(for photo: PhotoItem) -> URL {
        if photo.isSystem {
            if let derivative = photo.systemThumbnailPath,
               FileManager.default.fileExists(atPath: derivative) {
                return URL(fileURLWithPath: derivative)
            }
            return systemThumbs.appendingPathComponent(photo.id.uuidString + ".jpg")
        }
        return derivatives
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.id.uuidString + "_1_105_c.jpeg", isDirectory: false)
    }

    /// 网格快速层缩略图（约 192px）：独立小文件，滚动时秒开，缺失时按需生成。
    static func quickThumbnailURL(for photo: PhotoItem) -> URL {
        if photo.isSystem {
            return systemThumbs.appendingPathComponent(photo.id.uuidString + "_q.jpg", isDirectory: false)
        }
        return derivatives
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.id.uuidString + "_q.jpg", isDirectory: false)
    }

    static func sourceURL(for photo: PhotoItem) -> URL {
        if photo.isSystem, let path = photo.systemOriginalPath {
            return URL(fileURLWithPath: path)
        }
        if let editedFilename = photo.editedFilename {
            return edited.appendingPathComponent(editedFilename, isDirectory: false)
        }
        return originalURL(for: photo)
    }

    /// 注意：单参数的 `appendingPathComponent` 会为了判断目录去 lstat，
    /// 图库常在外置盘上，这条路径每次打开预览都会被调用，必须显式给 isDirectory。
    static func originalURL(for photo: PhotoItem) -> URL {
        originals
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.filename, isDirectory: false)
    }

    static func exportURL(for photo: PhotoItem) -> URL {
        if photo.isSystem, let path = photo.systemOriginalPath {
            return URL(fileURLWithPath: path)
        }
        if let editedFilename = photo.editedFilename {
            return edited.appendingPathComponent(editedFilename, isDirectory: false)
        }
        return originalURL(for: photo)
    }

    /// 实况照片的配对视频路径（本地库或系统图库）。
    static func livePhotoURL(for photo: PhotoItem) -> URL? {
        if let path = photo.livePhotoVideoPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let filename = photo.livePhotoFilename, !filename.isEmpty else { return nil }
        return originals
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    static func shard(for id: UUID) -> String {
        String(id.uuidString.prefix(1))
    }

    static func shard(forFilename filename: String) -> String {
        String(filename.prefix(1))
    }

    /// 切换容器。migratingLocalData 为 true 时把当前本地库迁入新图库的旁挂目录；
    /// 新建空图库时传 false，避免把旧库内容带进新库。
    @discardableResult
    static func switchContainer(to library: URL, migratingLocalData: Bool = true) -> Bool {
        guard isLibraryContainer(library) else { return false }
        prepareLibraryStructure(at: library)
        migrateSidecarToLibraryRootIfNeeded(at: library)
        let newRoot = library
        if newRoot.standardizedFileURL.path == root.standardizedFileURL.path {
            containerLibraryURL = library
            writeBootstrap(library.path)
            return true
        }

        let oldRoot = root
        let newDatabase = newRoot.appendingPathComponent("database/PhotosClone.sqlite")
        let needsMigration = !FileManager.default.fileExists(atPath: newDatabase.path)

        root = newRoot
        containerLibraryURL = library
        prepare()

        if needsMigration, migratingLocalData {
            // 先搬最早期的平铺目录，再搬当前的分片目录（originals / resources / database）。
            migrateLegacyLayoutIfNeeded()
            copyShardedContents(from: oldRoot, to: newRoot)
        }

        writeBootstrap(library.path)
        return true
    }

    /// 确保容器内具备 database / originals / resources 目录：
    /// 自建图库与官方「照片」图库都用包内第一层，官方库自带的目录已存在时不会改动。
    static func prepareLibraryStructure(at library: URL) {
        let directories = [
            library.appendingPathComponent("database", isDirectory: true),
            library.appendingPathComponent("originals", isDirectory: true),
            library.appendingPathComponent("resources/derivatives", isDirectory: true),
            library.appendingPathComponent("resources/renders", isDirectory: true)
        ]
        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func openContainerInPhotos() {
        guard let containerLibraryURL else { return }
        NSWorkspace.shared.open(containerLibraryURL)
    }

    // MARK: - Migration

    private static func migrateLegacyLayoutIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: metadataFile.path) else { return }
        let legacyDatabase = applicationRoot.appendingPathComponent("PhotosClone.sqlite")
        guard fm.fileExists(atPath: legacyDatabase.path) else { return }

        prepare()
        linkDirectory(legacyOriginals) { filename in
            originals
                .appendingPathComponent(shard(forFilename: filename), isDirectory: true)
                .appendingPathComponent(filename)
        }
        linkDirectory(legacyThumbs) { filename in
            let base = (filename as NSString).deletingPathExtension
            return derivatives
                .appendingPathComponent(shard(forFilename: base), isDirectory: true)
                .appendingPathComponent(base + "_1_105_c.jpeg")
        }
        linkDirectory(legacyEdited) { filename in
            edited.appendingPathComponent(filename)
        }

        for name in ["PhotosClone.sqlite", "PhotosClone.sqlite-wal", "PhotosClone.sqlite-shm"] {
            let source = applicationRoot.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = databaseDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }
        writeBootstrap(containerLibraryURL?.path ?? "local")
    }

    private static func copyShardedContents(from oldRoot: URL, to newRoot: URL) {
        let fm = FileManager.default
        for (sourceDir, destinationDir) in [
            (oldRoot.appendingPathComponent("originals"), newRoot.appendingPathComponent("originals")),
            (oldRoot.appendingPathComponent("resources/derivatives"), newRoot.appendingPathComponent("resources/derivatives")),
            (oldRoot.appendingPathComponent("resources/renders"), newRoot.appendingPathComponent("resources/renders"))
        ] {
            guard let enumerator = fm.enumerator(at: sourceDir,
                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                let relative = file.path.replacingOccurrences(of: sourceDir.path + "/", with: "")
                let destination = destinationDir.appendingPathComponent(relative)
                linkOrCopy(file, destination)
            }
        }
        for name in ["PhotosClone.sqlite", "PhotosClone.sqlite-wal", "PhotosClone.sqlite-shm"] {
            let source = oldRoot.appendingPathComponent("database").appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = newRoot.appendingPathComponent("database").appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }
    }

    private static func linkDirectory(_ sourceDir: URL, destination: (String) -> URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sourceDir,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for file in files {
            guard !file.hasDirectoryPath else { continue }
            linkOrCopy(file, destination(file.lastPathComponent))
        }
    }

    private static func linkOrCopy(_ source: URL, _ destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do {
            try fm.linkItem(at: source, to: destination)
        } catch {
            try? fm.copyItem(at: source, to: destination)
        }
    }

    private static func readBootstrap() -> String? {
        guard let value = try? String(contentsOf: bootstrapFile, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeBootstrap(_ value: String) {
        try? FileManager.default.createDirectory(at: applicationRoot, withIntermediateDirectories: true)
        try? value.write(to: bootstrapFile, atomically: true, encoding: .utf8)
    }

    private static func readLegacySystemLibraryPath() -> String? {
        let database = applicationRoot.appendingPathComponent("PhotosClone.sqlite")
        guard FileManager.default.fileExists(atPath: database.path),
              let db = try? SQLiteDatabase(path: database.path, readonly: true) else { return nil }
        return try? db.query("SELECT value FROM settings WHERE key = 'system_library_path'")
            .first?["value"]?.string
    }
}
