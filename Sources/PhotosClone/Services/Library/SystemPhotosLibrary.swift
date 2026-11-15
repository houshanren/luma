import Foundation

struct SystemLibrarySnapshot {
    let name: String
    let photos: [PhotoItem]
    let albums: [SystemAlbumInfo]
    let folders: [SystemFolderInfo]
    let people: [SystemPersonInfo]
    /// 图库实际可浏览的项目总数；`photos.count` 可能因加载上限而更少。
    var totalAssetCount: Int? = nil
}

/// 官方图库里已命名的人物 / 宠物（读取端侧识别结果，不额外做识别）。
struct SystemPersonInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let faceCount: Int
    let isPet: Bool
    let assetIDs: [UUID]
    let keyAssetID: UUID?
    let cropData: Data?
}

enum SystemLibraryError: LocalizedError {
    case invalidLibrary
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidLibrary: return "不是有效的照片图库（缺少 database/Photos.sqlite）"
        case .unsupported(let message): return "无法读取照片图库：\(message)"
        }
    }
}

/// 只读解析 macOS 官方「照片」图库（Photos.sqlite）。
enum SystemPhotosLibrary {
    static func scan(libraryURL: URL,
                     maxAssets: Int = 0,
                     progress: ((Int) -> Void)? = nil,
                     onBatch: (([PhotoItem]) -> Void)? = nil) throws -> SystemLibrarySnapshot {
        let databaseURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SystemLibraryError.invalidLibrary
        }

        let db = try SQLiteDatabase(path: databaseURL.path, readonly: true)

        // 部分旧版图库没有反向地理编码列，缺失时用 NULL 顶替，避免整条查询失败。
        let additionalColumns = (try? db.query("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)"))?
            .compactMap { $0["name"]?.string } ?? []
        let assetColumns = (try? db.query("PRAGMA table_info(ZASSET)"))?
            .compactMap { $0["name"]?.string } ?? []
        let placeColumn = additionalColumns.contains("ZREVERSELOCATIONDATA")
            ? "aa.ZREVERSELOCATIONDATA"
            : "NULL"
        let titleColumn = additionalColumns.contains("ZTITLE") ? "aa.ZTITLE" : "NULL"
        let subtypeColumn = assetColumns.contains("ZKINDSUBTYPE") ? "a.ZKINDSUBTYPE" : "NULL"
        let avalancheColumn = assetColumns.contains("ZAVALANCHEUUID") ? "a.ZAVALANCHEUUID" : "NULL"
        let playbackStyleColumn = assetColumns.contains("ZPLAYBACKSTYLE") ? "a.ZPLAYBACKSTYLE" : "NULL"
        let cameraDeviceColumn = assetColumns.contains("ZDERIVEDCAMERACAPTUREDEVICE")
            ? "a.ZDERIVEDCAMERACAPTUREDEVICE"
            : "NULL"
        let adjustmentColumn = assetColumns.contains("ZADJUSTMENTTIMESTAMP")
            ? "a.ZADJUSTMENTTIMESTAMP"
            : "NULL"
        let lastViewedColumn = additionalColumns.contains("ZLASTVIEWEDDATE") ? "aa.ZLASTVIEWEDDATE" : "NULL"

        // 有限额时先用 ZDATECREATED 覆盖索引取最近的 N 个主键，再回表连接；
        // 直接在 ZKIND 过滤后排序会让 SQLite 对整库做临时排序（百万级图库要几十秒）。
        let assetSource: String
        let binds: [Any?]
        if maxAssets > 0 {
            assetSource = """
                FROM (
                    SELECT Z_PK FROM ZASSET
                    WHERE ZDATECREATED IS NOT NULL
                    ORDER BY ZDATECREATED DESC
                    LIMIT ?
                ) picked
                JOIN ZASSET a ON a.Z_PK = picked.Z_PK
                """
            binds = [maxAssets]
        } else {
            assetSource = "FROM ZASSET a"
            binds = []
        }

        var photos: [PhotoItem] = []
        photos.reserveCapacity(4096)
        var pendingBatch: [PhotoItem] = []
        pendingBatch.reserveCapacity(4000)
        var assetIDByPK: [Int64: UUID] = [:]
        // 实况照片的配对视频：同名 MOV 与图片在同一图库中分别存储。
        var liveVideoByStem: [String: String] = [:]
        // 官方图库自带 derivative 时，逐项直接记录其路径，边扫描边显示也能用上快速缩略图。
        let hasDerivatives = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)

        do {
            try db.forEachRow("""
                SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZFILENAME AS filename,
                       a.ZDIRECTORY AS directory, a.ZKIND AS kind,
                       \(subtypeColumn) AS subtype,
                       \(avalancheColumn) AS avalanche,
                       \(playbackStyleColumn) AS playbackstyle,
                       \(cameraDeviceColumn) AS cameradevice,
                       \(adjustmentColumn) AS adjustmentdate,
                       \(lastViewedColumn) AS lastviewed,
                       a.ZFAVORITE AS favorite, a.ZHIDDEN AS hidden,
                       a.ZISDETECTEDSCREENSHOT AS screenshot,
                       a.ZTRASHEDSTATE AS trashed, a.ZTRASHEDDATE AS trasheddate,
                       a.ZDEPTHTYPE AS depth, a.ZDUPLICATEASSETVISIBILITYSTATE AS duplicate,
                       a.ZDATECREATED AS created, a.ZADDEDDATE AS added,
                       a.ZWIDTH AS width, a.ZHEIGHT AS height,
                       a.ZLATITUDE AS latitude, a.ZLONGITUDE AS longitude,
                       a.ZDURATION AS duration,
                       aa.ZORIGINALFILESIZE AS filesize,
                       aa.ZORIGINALWIDTH AS originalwidth, aa.ZORIGINALHEIGHT AS originalheight,
                       aa.ZORIGINALFILENAME AS originalname,
                       \(titleColumn) AS title,
                       aa.ZIMPORTEDBYBUNDLEIDENTIFIER AS importedby,
                       aa.ZEXIFTIMESTAMPSTRING AS exifdate,
                       \(placeColumn) AS placedata,
                       e.ZCAMERAMAKE AS make, e.ZCAMERAMODEL AS model, e.ZLENSMODEL AS lens,
                       e.ZAPERTURE AS aperture, e.ZFOCALLENGTH AS focal,
                       e.ZSHUTTERSPEED AS shutter, e.ZISO AS iso
                \(assetSource)
                LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
                LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
                WHERE a.ZKIND IN (0, 1)
                \(maxAssets > 0 ? "ORDER BY a.ZDATECREATED DESC" : "")
                """, binds) { row in
            guard let pk = row["pk"]?.int64,
                  let uuidString = row["uuid"]?.string,
                  let uuid = UUID(uuidString: uuidString),
                  let filename = row["filename"]?.string else { return }

            assetIDByPK[pk] = uuid
            let directory = row["directory"]?.string ?? String(uuidString.prefix(1))
            let originalURL = libraryURL
                .appendingPathComponent("originals")
                .appendingPathComponent(directory)
                .appendingPathComponent(filename)

            let width = row["originalwidth"]?.int ?? row["width"]?.int ?? 0
            let height = row["originalheight"]?.int ?? row["height"]?.int ?? 0
            let isVideo = (row["kind"]?.int ?? 0) == 1
            let isScreenshot = row["screenshot"]?.bool ?? false
            let subtype = row["subtype"]?.int ?? 0
            let playbackStyle = row["playbackstyle"]?.int ?? 0
            let isSelfie = (row["cameradevice"]?.int ?? 0) == 1

            if isVideo {
                let stem = originalURL.deletingPathExtension().lastPathComponent.lowercased()
                liveVideoByStem[stem] = originalURL.path
            }

            var kind: MediaKind = isVideo ? .video : .photo
            if !isVideo, isScreenshot || subtype == 6 || subtype == 10 {
                kind = .screenshot
            } else if !isVideo, subtype == 1 {
                kind = .panorama
            } else if !isVideo, isSelfie {
                kind = .selfie
            } else if !isVideo, width > 0, height > 0, CGFloat(width) / CGFloat(height) >= 2.2 {
                kind = .panorama
            }

            let createdAt = coreDataDate(row["created"])
            let addedAt = coreDataDate(row["added"]) ?? createdAt ?? Date()
            let capturedAt = createdAt ?? parseEXIFDate(row["exifdate"]?.string) ?? addedAt

            var item = PhotoItem(
                id: uuid,
                filename: filename,
                editedFilename: nil,
                originalName: row["originalname"]?.string ?? filename,
                capturedAt: capturedAt,
                addedAt: addedAt,
                pixelWidth: width,
                pixelHeight: height,
                fileSize: row["filesize"]?.int64 ?? 0,
                kind: kind
            )
            item.isFavorite = row["favorite"]?.bool ?? false
            item.isHidden = row["hidden"]?.bool ?? false
            item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
            item.isDuplicateItem = (row["duplicate"]?.int ?? 0) > 0
            // Photos.sqlite 的 ZKINDSUBTYPE：1 = 全景，2/3 = 实况照片，6/10 = 截屏，
            // 101 = 慢动作视频；ZPLAYBACKSTYLE：2 = 动图，3 = 实况照片。
            item.isLivePhoto = subtype == 2 || subtype == 3 || playbackStyle == 3
            item.isBurstItem = (row["avalanche"]?.string).map { !$0.isEmpty } ?? false
            item.isSlowMotion = isVideo && subtype == 101
            item.isScreenRecording = isVideo && isScreenshot
            item.isAnimated = !isVideo && playbackStyle == 2
            item.viewedAt = coreDataDate(row["lastviewed"])
            item.editedAt = coreDataDate(row["adjustmentdate"])
            if let title = trim(row["title"]?.string) {
                item.title = title
            }
            let importedBy = row["importedby"]?.string
            item.isDeviceImport = importedBy != nil
                && importedBy != "com.apple.Photos"
                && importedBy != "com.apple.mobileslideshow"
            if row["trashed"]?.bool ?? false {
                item.deletedAt = coreDataDate(row["trasheddate"]) ?? Date()
            }
            item.duration = row["duration"]?.double
            item.latitude = row["latitude"]?.double
            item.longitude = row["longitude"]?.double
            if !item.hasLocation {
                item.latitude = nil
                item.longitude = nil
            }
            if item.hasLocation,
               let placeData = row["placedata"]?.data,
               let place = ReverseGeoArchive.decode(placeData) {
                item.placeCountry = place.country
                item.placeProvince = place.province
                item.placeCity = place.city
                item.placeDistrict = place.district
                item.placePOI = place.poi
            }
            item.make = trim(row["make"]?.string)
            item.model = trim(row["model"]?.string)
            item.lens = trim(row["lens"]?.string)
            if let aperture = row["aperture"]?.double {
                item.aperture = String(format: "ƒ/%.1f", aperture)
            }
            if let focal = row["focal"]?.double {
                item.focalLength = String(format: "%.0f mm", focal)
            }
            if let shutter = row["shutter"]?.double, shutter > 0 {
                if shutter < 1 {
                    item.shutterSpeed = String(format: "1/%d 秒", Int((1 / shutter).rounded()))
                } else {
                    item.shutterSpeed = String(format: "%.1f 秒", shutter)
                }
            }
            if let iso = row["iso"]?.int {
                item.iso = "\(iso)"
            }
            if item.fileSize == 0,
               let size = try? originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                item.fileSize = Int64(size)
            }

            item.source = .system
            item.systemOriginalPath = originalURL.path
            if hasDerivatives {
                item.systemThumbnailPath = LibraryPaths.systemDerivativePath(
                    libraryURL: libraryURL,
                    assetID: item.id,
                    isVideo: item.kind == .video
                )
            }
            photos.append(item)
            pendingBatch.append(item)

            if pendingBatch.count >= 500 {
                progress?(photos.count)
                onBatch?(pendingBatch)
                pendingBatch.removeAll(keepingCapacity: true)
            }
        }
        if !pendingBatch.isEmpty {
            onBatch?(pendingBatch)
            pendingBatch.removeAll(keepingCapacity: true)
        }
        } catch {
            throw SystemLibraryError.unsupported(error.localizedDescription)
        }
        progress?(photos.count)

        // 为系统图库的实况照片关联配对视频（同名 MOV）。
        if !liveVideoByStem.isEmpty {
            for index in photos.indices
            where photos[index].isLivePhoto && photos[index].livePhotoVideoPath == nil {
                guard let path = photos[index].systemOriginalPath else { continue }
                let stem = URL(fileURLWithPath: path).deletingPathExtension()
                    .lastPathComponent.lowercased()
                if let video = liveVideoByStem[stem] {
                    photos[index].livePhotoVideoPath = video
                }
            }
        }

        let albumRows = try db.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZCREATIONDATE AS created
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """)

        var folders: [SystemFolderInfo] = []
        var folderPKs: Set<Int64> = []
        for row in albumRows where (row["kind"]?.int ?? 0) == 4000 {
            guard let pk = row["pk"]?.int64 else { continue }
            folderPKs.insert(pk)
            folders.append(SystemFolderInfo(id: pk,
                                            name: row["title"]?.string ?? "未命名文件夹",
                                            parent: row["parent"]?.int64,
                                            sortIndex: pk))
        }

        var members: [Int64: [UUID]] = [:]
        if let join = try? findAlbumAssetJoin(db) {
            try db.forEachRow("""
                SELECT "\(join.albumColumn)" AS album, "\(join.assetColumn)" AS asset,
                       "\(join.orderColumn ?? join.assetColumn)" AS position
                FROM "\(join.table)"
                ORDER BY album, position
                """) { row in
                guard let albumPK = row["album"]?.int64,
                      let assetPK = row["asset"]?.int64,
                      let uuid = assetIDByPK[assetPK] else { return }
                members[albumPK, default: []].append(uuid)
            }
        }

        var albums: [SystemAlbumInfo] = []
        for row in albumRows where (row["kind"]?.int ?? 0) == 2 {
            guard let pk = row["pk"]?.int64 else { continue }
            let parentPK = row["parent"]?.int64
            let parent = parentPK.flatMap { folderPKs.contains($0) ? $0 : nil }
            albums.append(SystemAlbumInfo(id: pk,
                                          name: row["title"]?.string ?? "未命名相簿",
                                          parentFolder: parent,
                                          assetIDs: members[pk] ?? [],
                                          sortIndex: pk))
        }

        // 修正文件夹父子关系（父节点可能尚未遍历到）。
        folders = folders.map { folder in
            let parent = folder.parent.flatMap { folderPKs.contains($0) ? $0 : nil }
            return SystemFolderInfo(id: folder.id, name: folder.name, parent: parent,
                                    sortIndex: folder.sortIndex)
        }

        let name = libraryURL.deletingPathExtension().lastPathComponent
        let totalAssets = (try? db.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int) ?? photos.count
        let people = (try? scanPeople(db, assetIDByPK: assetIDByPK)) ?? []
        return SystemLibrarySnapshot(name: name, photos: photos, albums: albums,
                                     folders: folders, people: people,
                                     totalAssetCount: totalAssets)
    }

    // MARK: - 人物

    private static func scanPeople(_ db: SQLiteDatabase,
                                   assetIDByPK: [Int64: UUID]) throws -> [SystemPersonInfo] {
        let personColumns = (try? db.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return [] }

        let faceColumns = (try? db.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else { return [] }

        var facesByPerson: [Int64: [UUID]] = [:]
        var seen: [Int64: Set<UUID>] = [:]
        try db.forEachRow("""
            SELECT ZPERSONFORFACE AS person, ZASSETFORFACE AS asset
            FROM ZDETECTEDFACE
            WHERE ZPERSONFORFACE IS NOT NULL AND ZASSETFORFACE IS NOT NULL
            """) { row in
            guard let personPK = row["person"]?.int64,
                  let assetPK = row["asset"]?.int64,
                  let uuid = assetIDByPK[assetPK] else { return }
            if seen[personPK, default: []].insert(uuid).inserted {
                facesByPerson[personPK, default: []].append(uuid)
            }
        }

        var crops: [Int64: Data] = [:]
        try? db.forEachRow("""
            SELECT ZPERSON AS person, ZRESOURCEDATA AS data FROM ZFACECROP
            WHERE ZPERSON IS NOT NULL AND ZRESOURCEDATA IS NOT NULL
            """) { row in
            if let personPK = row["person"]?.int64,
               let data = row["data"]?.data,
               crops[personPK] == nil {
                crops[personPK] = data
            }
        }

        let personRows = try db.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type, ZKEYFACE AS keyface
            FROM ZPERSON
            WHERE (ZDISPLAYNAME IS NOT NULL AND length(ZDISPLAYNAME) > 0)
               OR (ZFULLNAME IS NOT NULL AND length(ZFULLNAME) > 0)
            """)

        var people: [SystemPersonInfo] = []
        for row in personRows {
            guard let pk = row["pk"]?.int64 else { continue }
            let name = (row["display"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["full"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "未命名"
            let assetIDs = facesByPerson[pk] ?? []
            guard !assetIDs.isEmpty else { continue }

            var keyAssetID: UUID?
            if let keyfacePK = row["keyface"]?.int64,
               let keyRow = try? db.query("SELECT ZASSETFORFACE AS asset FROM ZDETECTEDFACE WHERE Z_PK = ?", [keyfacePK]).first,
               let assetPK = keyRow["asset"]?.int64 {
                keyAssetID = assetIDByPK[assetPK]
            }

            people.append(SystemPersonInfo(id: pk,
                                           name: name,
                                           faceCount: row["faces"]?.int ?? assetIDs.count,
                                           isPet: (row["type"]?.int ?? 0) == 1,
                                           assetIDs: assetIDs,
                                           keyAssetID: keyAssetID,
                                           cropData: crops[pk]))
        }
        return people.sorted {
            if $0.faceCount != $1.faceCount { return $0.faceCount > $1.faceCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private static func coreDataDate(_ value: SQLiteValue?) -> Date? {
        guard let raw = value?.double, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    private static func parseEXIFDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct AlbumAssetJoin {
        let table: String
        let albumColumn: String
        let assetColumn: String
        let orderColumn: String?
    }

    private static func findAlbumAssetJoin(_ db: SQLiteDatabase) throws -> AlbumAssetJoin? {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
        for tableRow in tables {
            guard let table = tableRow["name"]?.string, table.hasPrefix("Z_") else { continue }
            let columns = try db.query("PRAGMA table_info(\"\(table)\")")
            let names = columns.compactMap { $0["name"]?.string }
            guard let assetColumn = names.first(where: { $0 == "Z_3ASSETS" }),
                  let albumColumn = names.first(where: { isAlbumColumn($0) }) else { continue }
            let orderColumn = names.first(where: { $0 == "Z_FOK_3ASSETS" })
            return AlbumAssetJoin(table: table,
                                  albumColumn: albumColumn,
                                  assetColumn: assetColumn,
                                  orderColumn: orderColumn)
        }
        return nil
    }

    private static func isAlbumColumn(_ name: String) -> Bool {
        guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMS") else { return false }
        let middle = name.dropFirst(2).dropLast(6)
        return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
    }
}

// MARK: - 扫描结果缓存

/// 系统图库扫描结果缓存：命中时直接展示，避免每次重新解析 Photos.sqlite 与缩略图目录。
/// 只缓存索引与元数据，原图仍然直接从 macOS「照片」图库读取。
enum SystemLibraryCache {
    /// 解析逻辑或快照结构变更时递增，旧缓存会自动失效。
    /// v5：扫描时记录官方 derivative 路径，旧缓存需要重扫一次。
    static let version = 5
    private static let maxCacheFiles = 8
    /// 超大快照不做缓存，避免编码/解码占用过多内存。
    private static let maxCachedPhotos = 250_000

    struct Loaded {
        let snapshot: SystemLibrarySnapshot
        /// Photos.sqlite 未变化，缓存即最新，无需再扫描。
        let isFresh: Bool
    }

    private struct Payload: Codable {
        var version: Int
        var signature: String
        var name: String
        var photos: [PhotoItem]
        var albums: [SystemAlbumInfo]
        var folders: [SystemFolderInfo]
        var people: [SystemPersonInfo]
        var totalAssetCount: Int?
    }

    static func load(for libraryURL: URL) -> Loaded? {
        guard let signature = signature(for: libraryURL),
              let file = cacheFile(for: libraryURL),
              let data = try? Data(contentsOf: file),
              let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        let snapshot = SystemLibrarySnapshot(name: payload.name,
                                             photos: payload.photos,
                                             albums: payload.albums,
                                             folders: payload.folders,
                                             people: payload.people,
                                             totalAssetCount: payload.totalAssetCount)
        return Loaded(snapshot: snapshot, isFresh: payload.signature == signature)
    }

    static func save(_ snapshot: SystemLibrarySnapshot, for libraryURL: URL) {
        guard snapshot.photos.count <= maxCachedPhotos,
              let signature = signature(for: libraryURL),
              let file = cacheFile(for: libraryURL) else { return }
        let payload = Payload(version: version,
                              signature: signature,
                              name: snapshot.name,
                              photos: snapshot.photos,
                              albums: snapshot.albums,
                              folders: snapshot.folders,
                              people: snapshot.people,
                              totalAssetCount: snapshot.totalAssetCount)
        Task.detached(priority: .utility) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(payload) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: LibraryPaths.systemLibraryCacheDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            pruneOldFiles()
        }
    }

    /// 以 Photos.sqlite 的大小与修改时间判断图库是否变化。
    private static func signature(for libraryURL: URL) -> String? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let values = try? dbURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    private static func cacheFile(for libraryURL: URL) -> URL? {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return LibraryPaths.systemLibraryCacheDir
            .appendingPathComponent(String(hash, radix: 16) + ".plist")
    }

    private static func pruneOldFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: LibraryPaths.systemLibraryCacheDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]),
              files.count > maxCacheFiles else { return }
        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(maxCacheFiles) {
            try? fm.removeItem(at: file)
        }
    }
}
