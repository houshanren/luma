import Foundation

enum SystemIndexError: LocalizedError {
    case invalidLibrary
    case buildFailed(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidLibrary: return "不是有效的照片图库（缺少 database/Photos.sqlite）"
        case .buildFailed(let message): return "无法建立系统图库索引：\(message)"
        case .unreadable(let message): return "无法读取系统图库索引：\(message)"
        }
    }
}

/// 系统图库索引的聚合结果。
struct SystemIndexCounts {
    var active = 0
    var hidden = 0
    var trash = 0
    var duplicate = 0
    var recentlySaved = 0
    var imports = 0
    var portrait = 0
    var screenshots = 0
    var totalBytes: Int64 = 0
    var earliest: Date?
    var latest: Date?
}

/// 系统「照片」图库的元数据索引（`resources/system-cache/SystemIndex-<hash>.sqlite`）。
///
/// 百万级图库不再把整库 `[PhotoItem]` 装进内存：网格、计数、年/月总览、相簿与人物
/// 全部按窗口查询这个只读索引，常驻内存只有当前页与相簿名这类小数据。
/// `Photos.sqlite` 始终只读，索引文件写在当前图库自己的 `resources/system-cache/`。
final class SystemIndex {
    /// schema 或字段映射变化时递增，旧索引自动失效。
    /// v2：人物收录未命名聚类（与官方「照片」人物列表对齐），旧索引需要重建。
    /// v4：相簿 / 文件夹改用 Z_FOK_PARENTFOLDER 手动排序键，与官方「照片」侧边栏顺序对齐。
    /// v5：新增延时摄影标记（ZKINDSUBTYPE = 102）。
    /// v6：移除载入上限，索引始终收录整库，旧索引需要重建。
    /// v7：people 表新增关键人脸几何（facecx / facecy / facesize），
    /// 人物头像按官方「照片」的人脸口径现算裁切，旧索引需要重建。
    /// v8：assets 表新增连拍分组（burstuuid / burstpick），
    /// 「连拍快照」改为按组展示代表照片，旧索引需要重建。
    /// v9：人物裁切图改为只取与关键照片一致的那条（官方头像口径），旧索引需要重建。
    /// v10：共享相簿项目的缩略图改取 scopes/cloudsharing 下的封面帧，旧索引需要重建。
    static let version = 10
    /// 低于这个规模继续沿用内存快照（小库启动更快）。
    static let largeLibraryThreshold = 100_000

    let database: SQLiteDatabase
    let libraryURL: URL
    let name: String
    /// 索引里收录的项目数。
    let total: Int
    /// 图库真实总数。
    let trueTotal: Int
    let hasDerivatives: Bool
    /// 非空表示直连模式：database 指向系统 `Photos.sqlite`，不再维护本地索引。
    let direct: SystemDirectSource?
    /// 直连模式的侧边栏计数快照（精确值由后台任务补齐）。
    var directCounts: SystemDirectCounts?
    var directCountsWarmupTask: Task<Void, Never>?
    /// 直连模式的地图 / 位置数据（全量带定位照片），由后台任务填充。
    var directGeoPhotos: [PhotoItem]?
    /// 直连模式的地点名 → 资产 UUID：地名只存在二进制归档里，搜索时按它换算成 SQL 条件。
    var directPlaceTokenIndex: [String: [String]]?
    /// 导入批次概览缓存：一个批次的拍摄跨度不会变，按会话 id 缓存。
    var directImportSummaryCache: [Int64: SystemImportSessionSummary] = [:]
    var directGeoWarmupTask: Task<Void, Never>?
    /// 后台快照就绪时通知界面刷新（侧边栏计数、地图样本共用）。
    var onDirectCountsReady: (() -> Void)?
    var directPageCursors: [String: (offset: Int, value: Double, pk: Int64)] = [:]
    let directCursorLock = NSLock()
    /// 直连模式的时间轴密度（官方 `ZMOMENT` 的每个时刻与项目数），滚动条定位用。
    var directTimelineBuckets: [SystemTimelineBucket]?
    let directTimelineLock = NSLock()
    /// 相簿封面 / 数量的直连缓存：相簿概览会在 SwiftUI body 里逐个读取，
    /// 每次都查库会让上万相簿的滚动持续卡顿。系统库只读，本会话内不会变化。
    var directAlbumPreviewCache: [String: [PhotoItem]] = [:]
    var directImportSessionsCache: [SystemImportSession]?
    var directImportCoverCache: [Int64: PhotoItem] = [:]
    var directAlbumFirstCache: [Int64: PhotoItem] = [:]
    var directAlbumCountCache: [Int64: Int] = [:]
    var directFolderAlbumsCache: [Int64: [Int64]] = [:]
    /// 官方相簿 / 文件夹的父子表：整库只扫一次，侧边栏逐层展开时不再重复读 `ZGENERICALBUM`。
    var directFolderChildrenMap: [Int64: [Int64]]?
    var directFolderKindsMap: [Int64: Int]?
    var directFolderPreviewCache: [String: [UUID]] = [:]
    let directAlbumCacheLock = NSLock()

    init(database: SQLiteDatabase,
         libraryURL: URL,
         name: String,
         total: Int,
         trueTotal: Int,
         direct: SystemDirectSource? = nil) {
        self.database = database
        self.libraryURL = libraryURL
        self.name = name
        self.total = total
        self.trueTotal = trueTotal
        self.direct = direct
        self.hasDerivatives = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)
    }

    // MARK: - 打开 / 建立

    /// 官方图库的项目总数（含隐藏与最近删除，不含视频外的其它类型）。
    static func assetCount(libraryURL: URL) -> Int? {
        let url = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: url.path, readonly: true) else { return nil }
        return try? db.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int
    }

    /// 官方「照片」图库自带的关键词：`ZKEYWORD` 通过 `Z_1KEYWORDS` 关联到
    /// `ZADDITIONALASSETATTRIBUTES`，再由 `ZASSET` 得到资产 UUID。
    /// 返回「关键词 → 资产（按拍摄时间从新到旧）」及反查表；Photos.sqlite 只读。
    static func nativeKeywordMap(libraryURL: URL)
        -> (byKeyword: [String: [UUID]], byAsset: [UUID: [String]]) {
        let url = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: url.path, readonly: true) else {
            return ([:], [:])
        }
        let sql = """
            SELECT k.ZTITLE AS title, a.ZUUID AS uuid
            FROM ZKEYWORD k
            JOIN Z_1KEYWORDS j ON j.Z_53KEYWORDS = k.Z_PK
            JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK = j.Z_1ASSETATTRIBUTES
            JOIN ZASSET a ON a.Z_PK = aa.ZASSET
            WHERE a.ZKIND IN (0, 1)
            ORDER BY k.ZTITLE ASC, a.ZDATECREATED DESC
            """
        guard let rows = try? db.query(sql) else { return ([:], [:]) }
        var byKeyword: [String: [UUID]] = [:]
        var byAsset: [UUID: [String]] = [:]
        for row in rows {
            guard let title = row["title"]?.string, !title.isEmpty,
                  let raw = row["uuid"]?.string,
                  let id = UUID(uuidString: raw) else { continue }
            byKeyword[title, default: []].append(id)
            byAsset[id, default: []].append(title)
        }
        return (byKeyword, byAsset)
    }

    /// 打开已存在且与当前图库匹配的索引；不匹配返回 nil。
    static func openIfFresh(libraryURL: URL) -> SystemIndex? {
        guard let file = LibraryPaths.systemIndexFile(for: libraryURL),
              FileManager.default.fileExists(atPath: file.path),
              let signature = signature(for: libraryURL),
              let db = try? SQLiteDatabase(path: file.path, readonly: true) else { return nil }
        guard let meta = metaValues(db),
              meta["version"] == String(version),
              meta["signature"] == signature,
              let total = Int(meta["total"] ?? ""),
              let trueTotal = Int(meta["trueTotal"] ?? "") else { return nil }
        return SystemIndex(database: db,
                           libraryURL: libraryURL,
                           name: meta["name"] ?? libraryURL.deletingPathExtension().lastPathComponent,
                           total: total,
                           trueTotal: trueTotal)
    }

    /// 返回可用索引：命中缓存直接打开，否则从 `Photos.sqlite` 重建。
    /// 建立失败时抛错，由调用方回退到内存快照。
    /// `onBatch` 让重建过程也能逐批把照片交给界面，百万级图库不必等索引写完才出图。
    static func prepare(libraryURL: URL,
                        progress: ((Int) -> Void)? = nil,
                        isCancelled: () -> Bool = { false },
                        onBatch: (([PhotoItem]) -> Void)? = nil) throws -> SystemIndex {
        if let fresh = openIfFresh(libraryURL: libraryURL) {
            progress?(fresh.total)
            return fresh
        }
        return try build(libraryURL: libraryURL,
                         progress: progress,
                         isCancelled: isCancelled,
                         onBatch: onBatch)
    }

    private static func metaValues(_ db: SQLiteDatabase) -> [String: String]? {
        guard let rows = try? db.query("SELECT key, value FROM meta") else { return nil }
        var meta: [String: String] = [:]
        for row in rows {
            if let key = row["key"]?.string, let value = row["value"]?.string {
                meta[key] = value
            }
        }
        return meta
    }

    /// 以 Photos.sqlite 的大小与修改时间判断图库是否变化。
    private static func signature(for libraryURL: URL) -> String? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let values = try? dbURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    private static func build(libraryURL: URL,
                              progress: ((Int) -> Void)?,
                              isCancelled: () -> Bool,
                              onBatch: (([PhotoItem]) -> Void)?) throws -> SystemIndex {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SystemIndexError.invalidLibrary
        }
        guard let destination = LibraryPaths.systemIndexFile(for: libraryURL),
              let signature = signature(for: libraryURL) else {
            throw SystemIndexError.buildFailed("无法定位索引文件")
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let cacheDir = destination.deletingLastPathComponent()
        // 先清掉上一次中断的构建残留（含 -wal / -shm，单个可达数百 MB）。
        if let stale = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for url in stale where url.lastPathComponent.hasPrefix("SystemIndex-build-") {
                try? fm.removeItem(at: url)
            }
        }
        let temp = cacheDir
            .appendingPathComponent("SystemIndex-build-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(at: URL(fileURLWithPath: temp.path + suffix))
            }
        }

        let source = try SQLiteDatabase(path: sourceURL.path, readonly: true)
        // 索引建完只做只读打开，临时库不启用 WAL：避免主文件搬走后旁路文件留在原地，
        // 只读连接拿不到 -wal / -shm 时会直接 SQLITE_CANTOPEN（表现为图库永远转圈）。
        let target = try SQLiteDatabase(path: temp.path, readonly: false, wal: false)
        try target.execute("PRAGMA journal_mode=OFF;")
        try target.execute("PRAGMA synchronous=OFF;")
        try target.execute("PRAGMA temp_store=MEMORY;")

        // 逐列探测，兼容旧版图库缺失列。
        let additionalColumns = (try? source.query("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)"))?
            .compactMap { $0["name"]?.string } ?? []
        let assetColumns = (try? source.query("PRAGMA table_info(ZASSET)"))?
            .compactMap { $0["name"]?.string } ?? []
        let placeColumn = additionalColumns.contains("ZREVERSELOCATIONDATA") ? "aa.ZREVERSELOCATIONDATA" : "NULL"
        let titleColumn = additionalColumns.contains("ZTITLE") ? "aa.ZTITLE" : "NULL"
        let subtypeColumn = assetColumns.contains("ZKINDSUBTYPE") ? "a.ZKINDSUBTYPE" : "NULL"
        let avalancheColumn = assetColumns.contains("ZAVALANCHEUUID") ? "a.ZAVALANCHEUUID" : "NULL"
        let avalanchePickColumn = assetColumns.contains("ZAVALANCHEPICKTYPE") ? "a.ZAVALANCHEPICKTYPE" : "NULL"
        let playbackStyleColumn = assetColumns.contains("ZPLAYBACKSTYLE") ? "a.ZPLAYBACKSTYLE" : "NULL"
        let cameraDeviceColumn = assetColumns.contains("ZDERIVEDCAMERACAPTUREDEVICE")
            ? "a.ZDERIVEDCAMERACAPTUREDEVICE" : "NULL"
        let adjustmentColumn = assetColumns.contains("ZADJUSTMENTTIMESTAMP")
            ? "a.ZADJUSTMENTTIMESTAMP" : "NULL"
        let lastViewedColumn = additionalColumns.contains("ZLASTVIEWEDDATE") ? "aa.ZLASTVIEWEDDATE" : "NULL"

        // 与内存快照扫描保持一致：一律按拍摄日期从新到旧读取。
        // 用子查询固定顺序后 CROSS JOIN，避免在 JOIN 结果上直接 ORDER BY
        // （百万级图库会让 SQLite 做几十秒的临时排序），
        // 同时保证边建索引边显示时视频 / 截屏等分类能尽早出图。
        let assetSource: String
        let binds: [Any?] = []
        let orderClause = ""
        if assetColumns.contains("ZDATECREATED") {
            assetSource = """
                FROM (
                    SELECT Z_PK FROM ZASSET
                    WHERE ZDATECREATED IS NOT NULL
                    ORDER BY ZDATECREATED DESC
                    LIMIT -1
                ) picked
                CROSS JOIN ZASSET a ON a.Z_PK = picked.Z_PK
                """
        } else {
            assetSource = "FROM ZASSET a"
        }

        try target.transaction {
            try createSchema(target)
        }

        var inserted = 0
        var rows: [[Any?]] = []
        rows.reserveCapacity(500)
        // 逐批交给界面的照片（建索引期间先显示）。
        var batchItems: [PhotoItem] = []
        batchItems.reserveCapacity(500)
        var liveVideoByStem: [String: String] = [:]
        let trueTotal = (try? source.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int) ?? 0
        let derivativeCheck = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)

        let insertSQL = """
            INSERT INTO assets(
                pk, uuid, filename, origpath, thumbpath, mediakind, subtype, playbackstyle,
                cameradevice, favorite, hidden, screenshot, trashed, trasheddate, depth, duplicate,
                created, added, width, height, latitude, longitude, duration,
                filesize, originalwidth, originalheight, originalname, title, importedby, exifdate,
                placedata, placecountry, placeprovince, placecity, placedistrict, placepoi,
                make, model, lens, aperture, focal, shutter, iso,
                isvideo, islive, isburst, isslow, isscreenrec, isanimated, isdeviceimport,
                istimelapse,
                haslocation, israw, isedited, livevideopath, viewedat, editedat, inalbum, stem,
                burstuuid, burstpick
            ) VALUES (\(Array(repeating: "?", count: 61).joined(separator: ",")))
            """

        try target.transaction {
            try source.forEachRow("""
                SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZFILENAME AS filename,
                       a.ZDIRECTORY AS directory, a.ZKIND AS kind,
                       \(subtypeColumn) AS subtype,
                       \(avalancheColumn) AS avalanche,
                       \(avalanchePickColumn) AS avalanchepick,
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
                \(orderClause)
                """, binds) { row in
                if isCancelled() { throw SystemIndexError.buildFailed("已取消") }
                guard let pk = row["pk"]?.int64,
                      let uuidString = row["uuid"]?.string,
                      let uuid = UUID(uuidString: uuidString),
                      let filename = row["filename"]?.string else { return }
                let directory = row["directory"]?.string ?? String(uuidString.prefix(1))
                let originalURL = libraryURL
                    .appendingPathComponent("originals")
                    .appendingPathComponent(directory)
                    .appendingPathComponent(filename)
                let isVideo = (row["kind"]?.int ?? 0) == 1
                let stem = originalURL.deletingPathExtension().lastPathComponent.lowercased()
                if isVideo {
                    liveVideoByStem[stem] = originalURL.path
                }

                let width = row["originalwidth"]?.int ?? row["width"]?.int ?? 0
                let height = row["originalheight"]?.int ?? row["height"]?.int ?? 0
                let isScreenshot = row["screenshot"]?.bool ?? false
                let subtype = row["subtype"]?.int ?? 0
                let playbackStyle = row["playbackstyle"]?.int ?? 0
                let isSelfie = (row["cameradevice"]?.int ?? 0) == 1

                var kind: MediaKind = isVideo ? .video : .photo
                if !isVideo, isScreenshot || subtype == 6 || subtype == 10 {
                    kind = .screenshot
                } else if !isVideo, subtype == 1 {
                    kind = .panorama
                } else if !isVideo, isSelfie {
                    kind = .selfie
                } else if !isVideo, width > 0, height > 0,
                          CGFloat(width) / CGFloat(height) >= 2.2 {
                    kind = .panorama
                }

                let created = coreDataDate(row["created"])
                let added = coreDataDate(row["added"]) ?? created ?? Date()
                let captured = created ?? parseEXIFDate(row["exifdate"]?.string) ?? added
                let isLive = subtype == 2 || subtype == 3 || playbackStyle == 3
                let placedata = row["placedata"]?.data
                let place = placedata.flatMap { ReverseGeoArchive.decode($0) }
                let latitude = row["latitude"]?.double
                let longitude = row["longitude"]?.double
                let hasLocation = CoordinateValidator.isValid(latitude: latitude, longitude: longitude)
                let originalName = row["originalname"]?.string ?? filename
                let ext = (originalName as NSString).pathExtension.lowercased()
                let isRAW = Self.rawExtensions.contains(ext)
                let importedBy = row["importedby"]?.string
                let isDeviceImport = importedBy != nil
                    && importedBy != "com.apple.Photos"
                    && importedBy != "com.apple.mobileslideshow"
                let trashed = (row["trashed"]?.bool ?? false) ? (coreDataDate(row["trasheddate"]) ?? Date()) : nil
                let editedAt = coreDataDate(row["adjustmentdate"])
                let thumbPath = derivativeCheck
                    ? LibraryPaths.systemDerivativePath(libraryURL: libraryURL,
                                                        assetID: uuid,
                                                        isVideo: isVideo,
                                                        directory: directory)
                    : nil

                // 建索引期间先把这一行变成可显示的照片，交给界面边读边显示。
                if onBatch != nil {
                    var item = PhotoItem(
                        id: uuid,
                        filename: filename,
                        editedFilename: nil,
                        originalName: originalName,
                        capturedAt: captured,
                        addedAt: added,
                        pixelWidth: width,
                        pixelHeight: height,
                        fileSize: row["filesize"]?.int64 ?? 0,
                        kind: kind
                    )
                    item.isFavorite = row["favorite"]?.bool ?? false
                    item.isHidden = row["hidden"]?.bool ?? false
                    item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
                    item.isDuplicateItem = (row["duplicate"]?.int ?? 0) > 0
                    item.isLivePhoto = isLive
                    item.isBurstItem = (row["avalanche"]?.string).map { !$0.isEmpty } ?? false
                    item.isSlowMotion = isVideo && subtype == 101
                    item.isScreenRecording = isVideo && (isScreenshot || subtype == 103)
                    item.isAnimated = !isVideo && playbackStyle == 2
                    item.isTimelapse = isVideo && subtype == 102
                    item.viewedAt = coreDataDate(row["lastviewed"])
                    item.editedAt = editedAt
                    item.title = trimmed(row["title"]?.string)
                    item.isDeviceImport = isDeviceImport
                    item.deletedAt = trashed
                    item.duration = row["duration"]?.double
                    if hasLocation {
                        item.latitude = latitude
                        item.longitude = longitude
                        if let place {
                            item.placeCountry = place.country
                            item.placeProvince = place.province
                            item.placeCity = place.city
                            item.placeDistrict = place.district
                            item.placePOI = place.poi
                        }
                    }
                    item.make = trimmed(row["make"]?.string)
                    item.model = trimmed(row["model"]?.string)
                    item.lens = trimmed(row["lens"]?.string)
                    if let aperture = row["aperture"]?.double {
                        item.aperture = String(format: "ƒ/%.1f", aperture)
                    }
                    if let focal = row["focal"]?.double {
                        item.focalLength = String(format: "%.0f mm", focal)
                    }
                    if let shutter = row["shutter"]?.double, shutter > 0 {
                        item.shutterSpeed = shutter < 1
                            ? String(format: "1/%d 秒", Int((1 / shutter).rounded()))
                            : String(format: "%.1f 秒", shutter)
                    }
                    if let iso = row["iso"]?.int {
                        item.iso = "\(iso)"
                    }
                    item.source = .system
                    item.systemOriginalPath = originalURL.path
                    item.systemThumbnailPath = thumbPath
                    batchItems.append(item)
                }

                rows.append([
                    pk,
                    uuidString,
                    filename,
                    originalURL.path,
                    thumbPath,
                    kind.rawValue,
                    subtype,
                    playbackStyle,
                    row["cameradevice"]?.int ?? 0,
                    (row["favorite"]?.bool ?? false) ? 1 : 0,
                    (row["hidden"]?.bool ?? false) ? 1 : 0,
                    isScreenshot ? 1 : 0,
                    trashed?.timeIntervalSince1970,
                    trashed == nil ? nil : (row["trasheddate"]?.double ?? 0),
                    row["depth"]?.int ?? 0,
                    (row["duplicate"]?.int ?? 0) > 0 ? 1 : 0,
                    captured.timeIntervalSince1970,
                    added.timeIntervalSince1970,
                    width,
                    height,
                    hasLocation ? latitude : nil,
                    hasLocation ? longitude : nil,
                    row["duration"]?.double,
                    row["filesize"]?.int64 ?? 0,
                    row["originalwidth"]?.int ?? 0,
                    row["originalheight"]?.int ?? 0,
                    originalName,
                    trimmed(row["title"]?.string),
                    importedBy,
                    row["exifdate"]?.string,
                    placedata,
                    place?.country,
                    place?.province,
                    place?.city,
                    place?.district,
                    place?.poi,
                    trimmed(row["make"]?.string),
                    trimmed(row["model"]?.string),
                    trimmed(row["lens"]?.string),
                    row["aperture"]?.double,
                    row["focal"]?.double,
                    row["shutter"]?.double,
                    row["iso"]?.int,
                    isVideo ? 1 : 0,
                    isLive ? 1 : 0,
                    (row["avalanche"]?.string).map { !$0.isEmpty } == true ? 1 : 0,
                    (isVideo && subtype == 101) ? 1 : 0,
                    (isVideo && (isScreenshot || subtype == 103)) ? 1 : 0,
                    (!isVideo && playbackStyle == 2) ? 1 : 0,
                    isDeviceImport ? 1 : 0,
                    (isVideo && subtype == 102) ? 1 : 0,
                    hasLocation ? 1 : 0,
                    isRAW ? 1 : 0,
                    editedAt != nil ? 1 : 0,
                    nil as String?,
                    coreDataDate(row["lastviewed"])?.timeIntervalSince1970,
                    editedAt?.timeIntervalSince1970,
                    0,
                    stem,
                    trimmed(row["avalanche"]?.string),
                    ((row["avalanchepick"]?.int ?? 0) & 16) != 0 ? 1 : 0
                ])
                if rows.count >= 500 {
                    try target.executeMany(insertSQL, rows: rows)
                    inserted += rows.count
                    rows.removeAll(keepingCapacity: true)
                    progress?(inserted)
                    if let onBatch, !batchItems.isEmpty {
                        onBatch(batchItems)
                        batchItems.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !rows.isEmpty {
                try target.executeMany(insertSQL, rows: rows)
                inserted += rows.count
                rows.removeAll(keepingCapacity: true)
            }
            if let onBatch, !batchItems.isEmpty {
                onBatch(batchItems)
                batchItems.removeAll(keepingCapacity: true)
            }
            progress?(inserted)
            try linkLiveVideos(target, byStem: liveVideoByStem)
            try indexAlbums(source: source, target: target, assetCount: inserted)
            try indexPeople(source: source, target: target, isCancelled: isCancelled)
            try target.execute("UPDATE assets SET inalbum = 1 WHERE uuid IN (SELECT asset FROM album_assets)")
            try target.execute("CREATE INDEX idx_sys_created ON assets(created DESC)")
            try target.execute("CREATE INDEX idx_sys_added ON assets(added DESC)")
            try target.execute("CREATE INDEX idx_sys_size ON assets(filesize DESC)")
            try target.execute("CREATE INDEX idx_sys_title ON assets(title COLLATE NOCASE)")
            try target.execute("CREATE INDEX idx_sys_filename ON assets(filename COLLATE NOCASE)")
            try target.execute("CREATE INDEX idx_sys_duration ON assets(duration DESC)")
            try target.execute("CREATE INDEX idx_sys_uuid ON assets(uuid)")
            try target.execute("CREATE INDEX idx_sys_burst ON assets(burstuuid)")
            try target.execute("""
                CREATE INDEX idx_sys_album ON album_assets(album, position)
                """)
            try target.execute("CREATE INDEX idx_sys_album_asset ON album_assets(asset)")
            try target.execute("CREATE INDEX idx_sys_person ON person_assets(person)")
            let meta: [(String, String)] = [
                ("version", String(version)),
                ("signature", signature),
                ("total", String(inserted)),
                ("trueTotal", String(trueTotal)),
                ("name", libraryURL.deletingPathExtension().lastPathComponent),
                ("builtAt", String(Int(Date().timeIntervalSince1970)))
            ]
            for entry in meta {
                try target.execute("INSERT INTO meta(key, value) VALUES (?, ?)", [entry.0, entry.1])
            }
        }

        // 收尾：切回普通回滚日志模式，确保之后只读连接仅凭主文件即可查询。
        try target.execute("PRAGMA journal_mode=DELETE;")

        // 原子替换：先删旧索引（含 WAL/SHM），再把临时文件移到正式位置。
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
        }
        try fm.moveItem(at: temp, to: destination)
        let readonly = try SQLiteDatabase(path: destination.path, readonly: true)
        // 只读打开返回 OK 不代表能读：WAL 旁路文件缺失时要到 prepare 才报 SQLITE_CANTOPEN。
        // 这里先探一次，失败就让调用方回退到快照，避免图库卡在“正在读取图库…”。
        guard (try? readonly.query("SELECT COUNT(*) FROM assets")) != nil else {
            throw SystemIndexError.buildFailed("索引文件不可读")
        }
        return SystemIndex(database: readonly,
                           libraryURL: libraryURL,
                           name: libraryURL.deletingPathExtension().lastPathComponent,
                           total: inserted,
                           trueTotal: trueTotal)
    }

    private static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE assets(
                pk INTEGER PRIMARY KEY, uuid TEXT NOT NULL, filename TEXT NOT NULL,
                directory TEXT, origpath TEXT, thumbpath TEXT,
                kind INTEGER, mediakind TEXT, subtype INTEGER, playbackstyle INTEGER,
                cameradevice INTEGER, favorite INTEGER, hidden INTEGER, screenshot INTEGER,
                trashed REAL, trasheddate REAL, depth INTEGER, duplicate INTEGER,
                created REAL, added REAL, width INTEGER, height INTEGER,
                latitude REAL, longitude REAL, duration REAL,
                filesize INTEGER, originalwidth INTEGER, originalheight INTEGER,
                originalname TEXT NOT NULL, title TEXT, importedby TEXT, exifdate TEXT,
                placedata BLOB, placecountry TEXT, placeprovince TEXT, placecity TEXT,
                placedistrict TEXT, placepoi TEXT,
                make TEXT, model TEXT, lens TEXT,
                aperture REAL, focal REAL, shutter REAL, iso INTEGER,
                isvideo INTEGER, islive INTEGER, isburst INTEGER, isslow INTEGER,
                isscreenrec INTEGER, isanimated INTEGER, isdeviceimport INTEGER,
                istimelapse INTEGER,
                haslocation INTEGER, israw INTEGER, isedited INTEGER,
                livevideopath TEXT, viewedat REAL, editedat REAL,
                inalbum INTEGER, stem TEXT,
                burstuuid TEXT, burstpick INTEGER
            )
            """)
        try db.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
        try db.execute("""
            CREATE TABLE albums(pk INTEGER PRIMARY KEY, name TEXT, folder INTEGER, sortindex INTEGER, uuid TEXT)
            """)
        try db.execute("""
            CREATE TABLE folders(pk INTEGER PRIMARY KEY, name TEXT, parent INTEGER, sortindex INTEGER)
            """)
        try db.execute("CREATE TABLE album_assets(album INTEGER, asset TEXT, position INTEGER)")
        try db.execute("""
            CREATE TABLE people(pk INTEGER PRIMARY KEY, name TEXT, facecount INTEGER,
                                ispet INTEGER, keyasset TEXT, crop BLOB,
                                facecx REAL, facecy REAL, facesize REAL)
            """)
        try db.execute("CREATE TABLE person_assets(person INTEGER, asset TEXT)")
    }

    /// 实况照片的配对视频：同名 MOV 与图片在同一图库中分别存储。
    private static func linkLiveVideos(_ db: SQLiteDatabase, byStem: [String: String]) throws {
        guard !byStem.isEmpty else { return }
        guard let rows = try? db.query("SELECT uuid, stem FROM assets WHERE islive = 1") else { return }
        for row in rows {
            guard let uuid = row["uuid"]?.string,
                  let stem = row["stem"]?.string,
                  let path = byStem[stem] else { continue }
            try db.execute("UPDATE assets SET livevideopath = ? WHERE uuid = ?", [path, uuid])
        }
    }

    private static func indexAlbums(source: SQLiteDatabase,
                                    target: SQLiteDatabase,
                                    assetCount: Int) throws {
        let albumColumns = (try? source.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? []
        // Z_FOK_PARENTFOLDER 是 Core Data 为「父文件夹」有序关系保存的手动排序键，
        // 与官方「照片」侧边栏的显示顺序一致；旧图库没有该列时退回主键。
        let sortColumn = albumColumns.contains("Z_FOK_PARENTFOLDER") ? "Z_FOK_PARENTFOLDER" : "Z_PK"
        let albumRows = (try? source.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZUUID AS uuid, \(sortColumn) AS sortkey
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """)) ?? []
        var folderPKs: Set<Int64> = []
        var folderRows: [[Any?]] = []
        var albumRowsToWrite: [[Any?]] = []
        for row in albumRows {
            guard let pk = row["pk"]?.int64 else { continue }
            if (row["kind"]?.int ?? 0) == 4000 {
                folderPKs.insert(pk)
                folderRows.append([pk, row["title"]?.string ?? "未命名文件夹",
                                   row["parent"]?.int64, row["sortkey"]?.int64 ?? pk])
            }
        }
        for row in albumRows {
            guard let pk = row["pk"]?.int64, (row["kind"]?.int ?? 0) == 2 else { continue }
            let parent = row["parent"]?.int64.flatMap { folderPKs.contains($0) ? $0 : nil }
            albumRowsToWrite.append([pk, row["title"]?.string ?? "未命名相簿", parent,
                                     row["sortkey"]?.int64 ?? pk, row["uuid"]?.string])
        }
        folderRows = folderRows.map { row in
            let parent = (row[2] as? Int64).flatMap { folderPKs.contains($0) ? $0 : nil }
            return [row[0], row[1], parent, row[3]]
        }
        if !folderRows.isEmpty {
            try target.executeMany("INSERT INTO folders VALUES (?,?,?,?)", rows: folderRows)
        }
        if !albumRowsToWrite.isEmpty {
            try target.executeMany("INSERT INTO albums VALUES (?,?,?,?,?)", rows: albumRowsToWrite)
        }

        guard assetCount > 0, let join = findAlbumAssetJoin(source) else { return }
        var pending: [[Any?]] = []
        pending.reserveCapacity(1000)
        var position = 0
        var lastAlbum: Int64 = .min
        try source.forEachRow("""
            SELECT j."\(join.albumColumn)" AS album, a.ZUUID AS uuid,
                   j."\(join.orderColumn ?? join.assetColumn)" AS position
            FROM "\(join.table)" j
            JOIN ZASSET a ON a.Z_PK = j."\(join.assetColumn)"
            ORDER BY album, position
            """) { row in
            guard let album = row["album"]?.int64, let uuid = row["uuid"]?.string else { return }
            if album != lastAlbum {
                lastAlbum = album
                position = 0
            }
            pending.append([album, uuid, position])
            position += 1
            if pending.count >= 1000 {
                try target.executeMany("INSERT INTO album_assets VALUES (?,?,?)", rows: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try target.executeMany("INSERT INTO album_assets VALUES (?,?,?)", rows: pending)
        }
    }

    private static func indexPeople(source: SQLiteDatabase,
                                    target: SQLiteDatabase,
                                    isCancelled: () -> Bool) throws {
        let personColumns = (try? source.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return }
        let faceColumns = (try? source.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else { return }

        // 官方会为同一人物保留多条人脸裁切图（李晓希有 14 条），
        // 只有与关键照片一致的那条才是「照片」App 展示的头像，不能随便取第一条。
        var crops: [Int64: Data] = [:]
        let cropColumns = (try? source.query("PRAGMA table_info(ZFACECROP)"))?
            .compactMap { $0["name"]?.string } ?? []
        if cropColumns.contains("ZASSET") {
            try? source.forEachRow("""
                SELECT fc.ZPERSON AS person, fc.ZRESOURCEDATA AS data
                FROM ZFACECROP fc
                JOIN ZPERSON p ON p.Z_PK = fc.ZPERSON
                JOIN ZDETECTEDFACE kf ON kf.Z_PK = p.ZKEYFACE
                WHERE fc.ZRESOURCEDATA IS NOT NULL AND fc.ZASSET = kf.ZASSETFORFACE
                """) { row in
                if let person = row["person"]?.int64,
                   let data = row["data"]?.data,
                   crops[person] == nil {
                    crops[person] = data
                }
            }
        }

        // 官方「照片」的人物列表包含尚未命名的聚类，这里不按名称过滤，
        // 未命名时用「未命名」占位，保证与官方列出的人物数量一致。
        let personRows = (try? source.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type, ZKEYFACE AS keyface
            FROM ZPERSON
            """)) ?? []

        // 关键人脸几何（0-1 归一化：cx 相对图宽、cy 相对图高且原点在左下、size 相对图对角线），
        // 用于人物头像按官方口径从关键照片现算裁切；旧图库缺几何列时整体置空。
        var keyFaceGeometry: [Int64: (cx: Double, cy: Double, size: Double)] = [:]
        let hasFaceGeometry = (faceColumns.contains("ZCENTERX")
                               && faceColumns.contains("ZCENTERY")
                               && faceColumns.contains("ZSIZE"))
        if hasFaceGeometry {
            let geoRows = (try? source.query("""
                SELECT p.Z_PK AS person, f.ZCENTERX AS fcx, f.ZCENTERY AS fcy, f.ZSIZE AS fsize
                FROM ZPERSON p
                JOIN ZDETECTEDFACE f ON f.Z_PK = p.ZKEYFACE
                WHERE p.ZKEYFACE IS NOT NULL
                """)) ?? []
            for geoRow in geoRows {
                guard let person = geoRow["person"]?.int64,
                      let fcx = geoRow["fcx"]?.double,
                      let fcy = geoRow["fcy"]?.double,
                      let fsize = geoRow["fsize"]?.double else { continue }
                keyFaceGeometry[person] = (fcx, fcy, fsize)
            }
        }

        var keyFaceToPerson: [Int64: Int64] = [:]
        var peopleRows: [[Any?]] = []
        for row in personRows {
            guard let pk = row["pk"]?.int64 else { continue }
            let name = trimmed(row["display"]?.string)
                ?? trimmed(row["full"]?.string)
                ?? "未命名"
            let geometry = keyFaceGeometry[pk]
            peopleRows.append([pk, name, row["faces"]?.int ?? 0,
                               (row["type"]?.int ?? 0) == 1 ? 1 : 0,
                               nil as String?, crops[pk],
                               geometry?.cx, geometry?.cy, geometry?.size])
            if let keyface = row["keyface"]?.int64 {
                keyFaceToPerson[keyface] = pk
            }
        }
        if !peopleRows.isEmpty {
            try target.executeMany("""
                INSERT INTO people(pk, name, facecount, ispet, keyasset, crop, facecx, facecy, facesize)
                VALUES (?,?,?,?,?,?,?,?,?)
                """, rows: peopleRows)
        }

        var pending: [[Any?]] = []
        pending.reserveCapacity(1000)
        var seen: Set<String> = []
        var personCounts: [Int64: Int] = [:]
        try source.forEachRow("""
            SELECT f.ZPERSONFORFACE AS person, a.ZUUID AS uuid, f.Z_PK AS face
            FROM ZDETECTEDFACE f
            JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            WHERE f.ZPERSONFORFACE IS NOT NULL AND f.ZASSETFORFACE IS NOT NULL
            """) { row in
            if isCancelled() { throw SystemIndexError.buildFailed("已取消") }
            guard let person = row["person"]?.int64, let uuid = row["uuid"]?.string else { return }
            if let face = row["face"]?.int64, let owner = keyFaceToPerson[face] {
                try target.execute("UPDATE people SET keyasset = ? WHERE pk = ?", [uuid, owner])
            }
            let key = "\(person)|\(uuid)"
            guard seen.insert(key).inserted else { return }
            personCounts[person, default: 0] += 1
            pending.append([person, uuid])
            if pending.count >= 1000 {
                try target.executeMany("INSERT INTO person_assets VALUES (?,?)", rows: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try target.executeMany("INSERT INTO person_assets VALUES (?,?)", rows: pending)
        }
        for (person, count) in personCounts {
            try target.execute("UPDATE people SET facecount = ? WHERE pk = ?", [count, person])
        }
        // 没有照片的人物不展示（与内存快照一致）。
        try target.execute("DELETE FROM people WHERE pk NOT IN (SELECT person FROM person_assets)")
    }

    // MARK: - 相簿 / 文件夹 / 人物元数据

    /// 只读取相簿 / 文件夹结构（不含照片成员）：系统图库扫描或重建索引期间，
    /// 侧边栏可以先把相簿列表展示出来，不必等整库照片读完。
    static func albumMetadata(libraryURL: URL) -> (albums: [SystemAlbumInfo],
                                                   folders: [SystemFolderInfo]) {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let source = try? SQLiteDatabase(path: sourceURL.path, readonly: true) else {
            return ([], [])
        }
        let albumColumns = (try? source.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? []
        let sortColumn = albumColumns.contains("Z_FOK_PARENTFOLDER") ? "Z_FOK_PARENTFOLDER" : "Z_PK"
        let userSort = albumColumns.contains("ZCUSTOMSORTKEY") ? "ZCUSTOMSORTKEY" : "NULL"
        let userAsc = albumColumns.contains("ZCUSTOMSORTASCENDING") ? "ZCUSTOMSORTASCENDING" : "NULL"
        guard let rows = try? source.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZUUID AS uuid, \(sortColumn) AS sortkey,
                   \(userSort) AS usersort, \(userAsc) AS userasc
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """) else { return ([], []) }

        var folders: [SystemFolderInfo] = []
        var folderPKs: Set<Int64> = []
        var rawAlbums: [(pk: Int64, title: String, parent: Int64?, sortIndex: Int64, uuid: String?,
                        userSort: Int?, userAsc: Bool?)] = []
        for row in rows {
            guard let pk = row["pk"]?.int64 else { continue }
            let sortIndex = row["sortkey"]?.int64 ?? pk
            switch row["kind"]?.int ?? 0 {
            case 4000:
                folderPKs.insert(pk)
                folders.append(SystemFolderInfo(id: pk,
                                                name: row["title"]?.string ?? "未命名文件夹",
                                                parent: row["parent"]?.int64,
                                                sortIndex: sortIndex))
            case 2:
                rawAlbums.append((pk,
                                  row["title"]?.string ?? "未命名相簿",
                                  row["parent"]?.int64,
                                  sortIndex,
                                  row["uuid"]?.string,
                                  row["usersort"]?.int,
                                  row["userasc"]?.int.map { $0 != 0 }))
            default:
                break
            }
        }
        let resolvedFolders = folders.map { folder in
            SystemFolderInfo(id: folder.id,
                             name: folder.name,
                             parent: folder.parent.flatMap { folderPKs.contains($0) ? $0 : nil },
                             sortIndex: folder.sortIndex)
        }
        let resolvedAlbums = rawAlbums.map { item in
            SystemAlbumInfo(id: item.pk,
                            name: item.title,
                            parentFolder: item.parent.flatMap { folderPKs.contains($0) ? $0 : nil },
                            assetIDs: [],
                            sortIndex: item.sortIndex,
                            uuid: item.uuid,
                            customSortKey: item.userSort,
                            customSortAscending: item.userAsc)
        }
        return (resolvedAlbums, resolvedFolders)
    }

    /// 只读取人物结构（姓名 / 人脸数 / 头像裁剪 / 首张照片），
    /// 用于系统图库扫描或重建索引期间先把「人物」页展示出来。
    static func peopleMetadata(libraryURL: URL) -> [SystemPersonInfo] {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let source = try? SQLiteDatabase(path: sourceURL.path, readonly: true) else {
            return []
        }
        let personColumns = (try? source.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return [] }
        let faceColumns = (try? source.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else {
            return []
        }

        // 同一人物可能有多条裁切图，只认与关键照片一致的那条（官方头像口径）。
        var crops: [Int64: Data] = [:]
        let cropColumns = (try? source.query("PRAGMA table_info(ZFACECROP)"))?
            .compactMap { $0["name"]?.string } ?? []
        if cropColumns.contains("ZASSET") {
            try? source.forEachRow("""
                SELECT fc.ZPERSON AS person, fc.ZRESOURCEDATA AS data
                FROM ZFACECROP fc
                JOIN ZPERSON p ON p.Z_PK = fc.ZPERSON
                JOIN ZDETECTEDFACE kf ON kf.Z_PK = p.ZKEYFACE
                WHERE fc.ZRESOURCEDATA IS NOT NULL AND fc.ZASSET = kf.ZASSETFORFACE
                """) { row in
                if let person = row["person"]?.int64,
                   let data = row["data"]?.data,
                   crops[person] == nil {
                    crops[person] = data
                }
            }
        }

        // 只按每个人的关键人脸取一张照片，代价与人物数量成正比，不需要扫全部人脸。
        // 一并读取关键人脸几何（0-1 归一化，与官方「照片」的人物头像裁切口径一致）。
        let hasFaceGeometry = (faceColumns.contains("ZCENTERX")
                               && faceColumns.contains("ZCENTERY")
                               && faceColumns.contains("ZSIZE"))
        let geometryColumns = hasFaceGeometry
            ? "f.ZCENTERX AS fcx, f.ZCENTERY AS fcy, f.ZSIZE AS fsize"
            : "NULL AS fcx, NULL AS fcy, NULL AS fsize"
        var keyAssets: [Int64: String] = [:]
        var keyGeometry: [Int64: (cx: Double, cy: Double, size: Double)] = [:]
        let keyRows = (try? source.query("""
            SELECT p.Z_PK AS person, a.ZUUID AS uuid, \(geometryColumns)
            FROM ZPERSON p
            JOIN ZDETECTEDFACE f ON f.Z_PK = p.ZKEYFACE
            JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            WHERE p.ZKEYFACE IS NOT NULL
            """)) ?? []
        for row in keyRows {
            if let person = row["person"]?.int64, let uuid = row["uuid"]?.string {
                keyAssets[person] = uuid
            }
            if let person = row["person"]?.int64,
               let fcx = row["fcx"]?.double,
               let fcy = row["fcy"]?.double,
               let fsize = row["fsize"]?.double {
                keyGeometry[person] = (fcx, fcy, fsize)
            }
        }

        let rows = (try? source.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type
            FROM ZPERSON
            """)) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            let name = trimmed(row["display"]?.string)
                ?? trimmed(row["full"]?.string)
                ?? "未命名"
            return SystemPersonInfo(id: pk,
                                    name: name,
                                    faceCount: row["faces"]?.int ?? 0,
                                    isPet: (row["type"]?.int ?? 0) == 1,
                                    assetIDs: [],
                                    keyAssetID: keyAssets[pk].flatMap(UUID.init(uuidString:)),
                                    cropData: crops[pk],
                                    faceCenterX: keyGeometry[pk]?.cx,
                                    faceCenterY: keyGeometry[pk]?.cy,
                                    faceSize: keyGeometry[pk]?.size)
        }
        .sorted { lhs, rhs in
            if lhs.faceCount != rhs.faceCount { return lhs.faceCount > rhs.faceCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var albums: [SystemAlbumInfo] {
        if direct != nil { return directAlbums() }
        let rows = (try? database.query("SELECT pk, name, folder, sortindex, uuid FROM albums")) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemAlbumInfo(id: pk,
                                   name: row["name"]?.string ?? "未命名相簿",
                                   parentFolder: row["folder"]?.int64,
                                   assetIDs: [],
                                   sortIndex: row["sortindex"]?.int64 ?? pk,
                                   uuid: row["uuid"]?.string)
        }
    }

    var folders: [SystemFolderInfo] {
        if direct != nil { return directFolders() }
        let rows = (try? database.query("SELECT pk, name, parent, sortindex FROM folders")) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemFolderInfo(id: pk,
                                    name: row["name"]?.string ?? "未命名文件夹",
                                    parent: row["parent"]?.int64,
                                    sortIndex: row["sortindex"]?.int64 ?? pk)
        }
    }

    /// 官方导入会话（按导入时间从新到旧）。
    var importSessions: [SystemImportSession] {
        if direct != nil { return directImportSessions() }
        return []
    }

    func importSessionCover(_ id: Int64) -> PhotoItem? {
        if direct != nil { return directImportSessionCover(id) }
        return nil
    }

    /// 导入批次的拍摄跨度与视频数量。
    func importSessionSummary(_ id: Int64) -> SystemImportSessionSummary? {
        if direct != nil { return directImportSessionSummary(id) }
        return nil
    }

    var people: [SystemPersonInfo] {
        if direct != nil { return directPeople() }
        let rows = (try? database.query("""
            SELECT pk, name, facecount, ispet, keyasset, crop,
                   facecx, facecy, facesize FROM people ORDER BY facecount DESC, name
            """)) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemPersonInfo(id: pk,
                                    name: row["name"]?.string ?? "未命名",
                                    faceCount: row["facecount"]?.int ?? 0,
                                    isPet: (row["ispet"]?.int ?? 0) == 1,
                                    assetIDs: [],
                                    keyAssetID: row["keyasset"]?.string.flatMap(UUID.init(uuidString:)),
                                    cropData: row["crop"]?.data,
                                    faceCenterX: row["facecx"]?.double,
                                    faceCenterY: row["facecy"]?.double,
                                    faceSize: row["facesize"]?.double)
        }
    }

    func albumAssetIDs(_ albumID: Int64) -> [UUID] {
        if direct != nil { return directAlbumAssetIDs(albumID) }
        let rows = (try? database.query(
            "SELECT asset FROM album_assets WHERE album = ? ORDER BY position", [albumID])) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func albumAssetCount(_ albumID: Int64) -> Int {
        if direct != nil { return directAlbumAssetCount(albumID) }
        return (try? database.query("SELECT COUNT(*) AS c FROM album_assets WHERE album = ?", [albumID])
            .first?["c"]?.int) ?? 0
    }

    /// 相簿封面：按官方相簿顺序取第一张。
    func firstAlbumPhoto(_ albumID: Int64) -> PhotoItem? {
        if direct != nil { return directFirstAlbumPhoto(albumID) }
        let rows = try? database.query("""
            SELECT assets.* FROM assets
            JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = ?
            ORDER BY aa.position LIMIT 1
            """, [albumID])
        return rows?.first.flatMap { photo(from: $0) }
    }

    /// 相簿前若干张可用封面：按官方相簿顺序，跳过已删除与隐藏项目。
    func albumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        if direct != nil { return directAlbumPreviewPhotos(albumID, limit: limit) }
        let rows = try? database.query("""
            SELECT assets.* FROM assets
            JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = ?
            WHERE assets.trashed IS NULL AND assets.hidden = 0
            ORDER BY aa.position LIMIT \(limit)
            """, [albumID])
        return rows?.compactMap { photo(from: $0) } ?? []
    }

    /// 文件夹子树下所有相簿里的项目 ID（去重）；用于「拷贝到拾光」。
    func folderAssetIDs(_ folderID: Int64) -> [UUID] {
        if direct != nil { return directFolderAssetIDs(folderID) }
        let albumIDs = albumIDs(inFolder: folderID)
        guard !albumIDs.isEmpty else { return [] }
        let list = inList(albumIDs.map(String.init))
        let rows = (try? database.query("""
            SELECT DISTINCT asset FROM album_assets WHERE album IN (\(list))
            """)) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func folderPreviewAssetIDs(_ folderID: Int64, limit: Int) -> [UUID] {
        guard limit > 0 else { return [] }
        if direct != nil { return directFolderPreviewAssetIDs(folderID, limit: limit) }
        let albumIDs = albumIDs(inFolder: folderID)
        guard !albumIDs.isEmpty else { return [] }
        let list = inList(albumIDs.map(String.init))
        let rows = (try? database.query("""
            SELECT DISTINCT asset FROM album_assets WHERE album IN (\(list)) LIMIT \(limit)
            """)) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func personAssetIDs(_ personID: Int64) -> [UUID] {
        if direct != nil { return directPersonAssetIDs(personID) }
        let rows = (try? database.query(
            "SELECT asset FROM person_assets WHERE person = ?", [personID])) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func albumIDs(inFolder folderID: Int64) -> [Int64] {
        if direct != nil { return directAlbumIDs(inFolder: folderID) }
        let all = (try? database.query("SELECT pk, folder FROM albums")) ?? []
        var children: [Int64: [Int64]] = [:]
        for row in all {
            guard let pk = row["pk"]?.int64 else { continue }
            if let folder = row["folder"]?.int64 {
                children[folder, default: []].append(pk)
            }
        }
        let folderChildren = (try? database.query("SELECT pk, parent FROM folders")) ?? []
        var folderTree: [Int64: [Int64]] = [:]
        for row in folderChildren {
            guard let pk = row["pk"]?.int64, let parent = row["parent"]?.int64 else { continue }
            folderTree[parent, default: []].append(pk)
        }
        var result: [Int64] = []
        func walk(_ id: Int64) {
            result.append(contentsOf: children[id] ?? [])
            for child in folderTree[id] ?? [] { walk(child) }
        }
        walk(folderID)
        return result
    }

    /// 某张照片所属的相簿名称。
    func albumNames(containing id: UUID) -> [String] {
        if direct != nil { return directAlbumNames(containing: id) }
        let rows = (try? database.query("""
            SELECT a.name AS name FROM album_assets aa JOIN albums a ON a.pk = aa.album
            WHERE aa.asset = ?
            """, [id.uuidString])) ?? []
        return rows.compactMap { $0["name"]?.string }
    }

    // MARK: - 计数

    /// 侧边栏徽标：一次聚合查询算完所有计数。
    func counts(overrides: SystemQuery) -> SystemIndexCounts {
        if direct != nil { return directSidebarCounts() }
        let active = activePredicate(overrides)
        let savedCutoff = (overrides.savedCutoff ?? Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
            .timeIntervalSince1970
        let sql = """
            SELECT
                COUNT(*) AS total,
                COALESCE(SUM(CASE WHEN trashed IS NOT NULL THEN 1 ELSE 0 END), 0) AS trash,
                COALESCE(SUM(CASE WHEN \(active) THEN 1 ELSE 0 END), 0) AS active,
                COALESCE(SUM(CASE WHEN \(active) AND hidden = 1 THEN 1 ELSE 0 END), 0) AS hidden,
                COALESCE(SUM(CASE WHEN \(active) AND duplicate = 1 THEN 1 ELSE 0 END), 0) AS duplicate,
                COALESCE(SUM(CASE WHEN \(active) AND added >= \(savedCutoff) THEN 1 ELSE 0 END), 0) AS recentlySaved,
                COALESCE(SUM(CASE WHEN \(active) AND isdeviceimport = 1 THEN 1 ELSE 0 END), 0) AS imports,
                COALESCE(SUM(CASE WHEN \(active) AND depth > 0 AND isvideo = 0 THEN 1 ELSE 0 END), 0) AS portrait,
                COALESCE(SUM(CASE WHEN \(active) AND mediakind = 'screenshot' THEN 1 ELSE 0 END), 0) AS screenshots,
                COALESCE(SUM(CASE WHEN trashed IS NULL THEN filesize ELSE 0 END), 0) AS bytes,
                MIN(CASE WHEN \(active) THEN created END) AS earliest,
                MAX(CASE WHEN \(active) THEN created END) AS latest
            FROM assets
            """
        guard let row = try? database.query(sql).first else { return SystemIndexCounts() }
        var counts = SystemIndexCounts()
        counts.trash = row["trash"]?.int ?? 0
        counts.active = row["active"]?.int ?? 0
        counts.hidden = row["hidden"]?.int ?? 0
        counts.duplicate = row["duplicate"]?.int ?? 0
        counts.recentlySaved = row["recentlySaved"]?.int ?? 0
        counts.imports = row["imports"]?.int ?? 0
        counts.portrait = row["portrait"]?.int ?? 0
        counts.screenshots = row["screenshots"]?.int ?? 0
        counts.totalBytes = row["bytes"]?.int64 ?? 0
        counts.earliest = row["earliest"]?.double.map { Date(timeIntervalSince1970: $0) }
        counts.latest = row["latest"]?.double.map { Date(timeIntervalSince1970: $0) }
        return counts
    }

    /// 身份卡统计：有效（不含隐藏 / 最近删除）的照片与视频数量，一次聚合查询算完。
    func activeMediaTotals() -> (photos: Int, videos: Int) {
        if direct != nil {
            let summary = directMediaTypeSummary()
            let videos = summary.counts[.videos] ?? 0
            let active = directSidebarCounts().active
            return (max(0, active - videos), videos)
        }
        let active = activePredicate(SystemQuery())
        let sql = """
            SELECT
                COALESCE(SUM(CASE WHEN \(active) AND isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos,
                COALESCE(SUM(CASE WHEN \(active) AND isvideo = 0 THEN 1 ELSE 0 END), 0) AS photos
            FROM assets
            """
        guard let row = try? database.query(sql).first else { return (0, 0) }
        return (row["photos"]?.int ?? 0, row["videos"]?.int ?? 0)
    }

    /// 媒体类型总览：数量 + 每类第一张封面。
    func mediaTypeSummary(overrides: SystemQuery) -> MediaTypeSummary {
        if direct != nil { return directMediaTypeSummary() }
        var summary = MediaTypeSummary()
        for type in MediaTypeKey.allCases {
            var query = overrides
            switch type {
            case .videos: query.scope = .videos
            case .selfies: query.scope = .selfies
            case .livePhotos: query.scope = .livePhotos
            case .portraits: query.scope = .portraits
            case .panoramas: query.scope = .panoramas
            case .timelapse: query.scope = .timelapses
            case .slowMotion: query.scope = .slowMotion
            case .bursts: query.scope = .bursts
            case .screenshots: query.scope = .screenshots
            case .screenRecordings: query.scope = .screenRecordings
            case .animated: query.scope = .animated
            case .raws: query.scope = .raws
            // 长曝光 / 电影效果 / 空间媒体需要 PhotoKit 或直连 Photos.sqlite，本地索引模式跳过。
            case .longExposure, .cinematic, .spatial: continue
            }
            query.filter = .all
            query.tokens = []
            query.overlayKeywordIDs = nil
            let summaryValue = self.summary(query)
            guard summaryValue.total > 0 else { continue }
            summary.counts[type] = summaryValue.total
            summary.covers[type] = page(query, offset: 0, limit: 1).first
        }
        return summary
    }

    /// 重复项目：使用官方 `isDuplicateItem` 标记（拾光的重复页会再按大小/尺寸分组）。
    /// 上限要覆盖官方标出的全部重复项（本机 3.4 万级），否则重复页只显示前 2 万条。
    func duplicatePhotos(limit: Int = 60_000) -> [PhotoItem] {
        if direct != nil { return directDuplicatePhotos(limit: limit) }
        var query = SystemQuery()
        query.scope = .duplicates
        return page(query, offset: 0, limit: limit)
    }

    /// 带位置的照片：地图与足迹回放使用全量，统计与地点数不做任何截断。
    /// 逐行解码，避免先把整表物化成字典再转 `PhotoItem`（大图库内存峰值明显更低）。
    func photosWithLocation() -> [PhotoItem] {
        if direct != nil {
            // 直连模式的后台任务会读入全量带定位照片；就绪前先给最近的一小段，
            // 地图 / 地点页不至于空白。
            if let all = directGeoPhotos { return all }
            var query = SystemQuery()
            query.scope = .withLocation
            return directPage(query, offset: 0, limit: 600)
        }
        var query = SystemQuery()
        query.scope = .withLocation
        query.sortKey = .capturedAt
        query.ascending = false
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT assets.* FROM \(from) WHERE \(whereSQL)
            ORDER BY \(orderExpression(query)) DESC,
                     assets.uuid DESC
            """
        var photos: [PhotoItem] = []
        photos.reserveCapacity(summary(query).total)
        _ = try? database.forEachRow(sql, fromBinds + binds) { row in
            if let photo = self.photo(from: row) {
                photos.append(photo)
            }
        }
        return photos
    }

    // MARK: - 查询

    func summary(_ query: SystemQuery) -> PhotoQuerySummary {
        if direct != nil { return directSummary(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos
            FROM \(from) WHERE \(whereSQL)
            """
        guard let row = try? database.query(sql, fromBinds + binds).first else {
            return PhotoQuerySummary(total: 0, videos: 0)
        }
        return PhotoQuerySummary(total: row["total"]?.int ?? 0,
                                 videos: row["videos"]?.int ?? 0)
    }

    func page(_ query: SystemQuery, offset: Int, limit: Int) -> [PhotoItem] {
        if direct != nil { return directPage(query, offset: offset, limit: limit) }
        guard limit > 0 else { return [] }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT assets.* FROM \(from) WHERE \(whereSQL)
            ORDER BY \(orderExpression(query)) \(query.ascending ? "ASC" : "DESC"),
                     assets.uuid \(query.ascending ? "ASC" : "DESC")
            LIMIT ? OFFSET ?
            """
        guard let rows = try? database.query(sql, fromBinds + binds + [limit, max(0, offset)]) else {
            return []
        }
        return rows.compactMap { photo(from: $0) }
    }

    /// 当前查询下的全部项目 ID（只取 uuid 列）：供 ⌘A 全选当前范围的全部照片，
    /// 不受分页窗口只加载了一页的限制。
    func allIDs(_ query: SystemQuery) -> [UUID] {
        if direct != nil { return directAllIDs(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        var ids: [UUID] = []
        try? database.forEachRow("SELECT assets.uuid AS uuid FROM \(from) WHERE \(whereSQL)",
                                  fromBinds + binds) { row in
            if let value = row["uuid"]?.string, let id = UUID(uuidString: value) {
                ids.append(id)
            }
        }
        return ids
    }

    func photos(in query: SystemQuery, range: Range<Int>) -> [PhotoItem] {
        guard range.lowerBound >= 0, range.count > 0 else { return [] }
        return page(query, offset: range.lowerBound, limit: range.count)
    }

    /// 某张照片在当前查询排序中的下标（0 起）。
    func index(of id: UUID, in query: SystemQuery) -> Int? {
        if direct != nil { return nil }
        guard let target = sortValue(of: id, in: query) else { return nil }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let expr = orderExpression(query)
        let comparison = query.ascending ? "<" : ">"
        let sql = """
            SELECT COUNT(*) AS c FROM \(from)
            WHERE \(whereSQL) AND ((\(expr) \(comparison) ?) OR (\(expr) = ? AND assets.uuid \(comparison) ?))
            """
        guard let row = try? database.query(sql, fromBinds + binds + [target.value, target.value, id.uuidString]).first else {
            return nil
        }
        return row["c"]?.int
    }

    /// 当前查询排序下相邻的一张（delta 只能为 ±1），到两端环绕。
    func neighbor(of id: UUID, delta: Int, in query: SystemQuery) -> PhotoItem? {
        if direct != nil { return directNeighbor(of: id, delta: delta, in: query) }
        guard abs(delta) == 1 else { return nil }
        guard let current = index(of: id, in: query) else { return nil }
        let count = summary(query).total
        guard count > 0 else { return nil }
        var next = current + delta
        if next < 0 { next += count }
        if next >= count { next -= count }
        return page(query, offset: next, limit: 1).first
    }

    func photo(id: UUID) -> PhotoItem? {
        if direct != nil { return directPhoto(id: id) }
        guard let row = try? database.query("SELECT * FROM assets WHERE uuid = ?", [id.uuidString]).first else {
            return nil
        }
        return photo(from: row)
    }

    /// 连拍组的全部成员（按拍摄时间升序）：查看器组内浏览与连拍播放用。
    func burstMembers(groupID: String) -> [PhotoItem] {
        if direct != nil { return directBurstMembers(groupID: groupID) }
        guard let rows = try? database.query(
            "SELECT * FROM assets WHERE burstuuid = ? ORDER BY created ASC, pk ASC", [groupID]) else {
            return []
        }
        return rows.compactMap { photo(from: $0) }
    }

    /// 按 ID 批量取照片，保持输入顺序。
    func photos(ids: [UUID]) -> [PhotoItem] {
        if direct != nil { return directPhotos(ids: ids) }
        guard !ids.isEmpty else { return [] }
        var byID: [UUID: PhotoItem] = [:]
        var start = 0
        while start < ids.count {
            let end = min(start + 500, ids.count)
            let chunk = ids[start..<end]
            let list = inList(chunk.map(\.uuidString))
            if let rows = try? database.query("SELECT * FROM assets WHERE uuid IN (\(list))") {
                for row in rows {
                    if let item = photo(from: row) { byID[item.id] = item }
                }
            }
            start = end
        }
        return ids.compactMap { byID[$0] }
    }

    // MARK: - 人物摘要

    /// 某个查询范围内的人物摘要：计数、年度、地点、时段、高光与同框人物全部由 SQLite 聚合，
    /// 不把整库照片读进内存。
    func personInsight(_ query: SystemQuery) -> PersonInsight {
        if direct != nil { return directPersonInsight(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let base = fromBinds + binds

        var total = 0
        var videos = 0
        var earliest: Date?
        var latest: Date?
        if let row = try? database.query("""
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos,
                   MIN(created) AS earliest,
                   MAX(created) AS latest
            FROM \(from) WHERE \(whereSQL)
            """, base).first {
            total = row["total"]?.int ?? 0
            videos = row["videos"]?.int ?? 0
            earliest = row["earliest"]?.double.map { Date(timeIntervalSince1970: $0) }
            latest = row["latest"]?.double.map { Date(timeIntervalSince1970: $0) }
        }

        let yearRows = (try? database.query("""
            SELECT strftime('%Y', created, 'unixepoch', 'localtime') AS period,
                   COUNT(*) AS c
            FROM \(from) WHERE \(whereSQL)
            GROUP BY period ORDER BY period
            """, base)) ?? []
        let years = yearRows.compactMap { row -> PersonInsight.YearCount? in
            guard let text = row["period"]?.string, let year = Int(text) else { return nil }
            return PersonInsight.YearCount(year: year, count: row["c"]?.int ?? 0)
        }

        let placeRows = (try? database.query("""
            SELECT placecity AS name, COUNT(*) AS c
            FROM \(from)
            WHERE \(whereSQL) AND placecity IS NOT NULL AND length(placecity) > 0
            GROUP BY placecity ORDER BY c DESC, name LIMIT 4
            """, base)) ?? []
        let places = placeRows.compactMap { row -> PersonInsight.PlaceCount? in
            guard let name = row["name"]?.string, !name.isEmpty else { return nil }
            return PersonInsight.PlaceCount(name: name, count: row["c"]?.int ?? 0)
        }

        let hourRows = (try? database.query("""
            SELECT strftime('%H', created, 'unixepoch', 'localtime') AS hour,
                   COUNT(*) AS c
            FROM \(from) WHERE \(whereSQL)
            GROUP BY hour
            """, base)) ?? []
        var hourCounts: [Int: Int] = [:]
        for row in hourRows {
            guard let text = row["hour"]?.string, let hour = Int(text) else { continue }
            hourCounts[hour] = row["c"]?.int ?? 0
        }

        let highlightRows = (try? database.query("""
            SELECT assets.* FROM \(from)
            WHERE \(whereSQL) AND isvideo = 0
            ORDER BY (favorite = 1) DESC, (pixelwidth * pixelheight) DESC, created DESC
            LIMIT 8
            """, base)) ?? []
        let highlights = highlightRows.compactMap { photo(from: $0) }

        var companions: [PersonInsight.Companion] = []
        if case .person(let personID) = query.scope {
            let rows = (try? database.query("""
                SELECT pa2.person AS pk, COUNT(DISTINCT pa2.asset) AS c
                FROM person_assets pa
                JOIN person_assets pa2 ON pa2.asset = pa.asset AND pa2.person <> pa.person
                JOIN assets ON assets.uuid = pa2.asset AND assets.trashed IS NULL
                WHERE pa.person = ?
                GROUP BY pa2.person ORDER BY c DESC LIMIT 3
                """, [personID])) ?? []
            let ids = rows.compactMap { $0["pk"]?.int64 }
            if !ids.isEmpty {
                let peopleRows = (try? database.query(
                    "SELECT pk, name, crop FROM people WHERE pk IN (\(inList(ids.map(String.init))))")) ?? []
                var names: [Int64: String] = [:]
                var crops: [Int64: Data] = [:]
                for row in peopleRows {
                    guard let pk = row["pk"]?.int64 else { continue }
                    names[pk] = row["name"]?.string ?? "未命名"
                    if let data = row["crop"]?.data { crops[pk] = data }
                }
                companions = rows.compactMap { row in
                    guard let pk = row["pk"]?.int64, let name = names[pk] else { return nil }
                    return PersonInsight.Companion(id: "system-\(pk)",
                                                   name: name,
                                                   count: row["c"]?.int ?? 0,
                                                   coverPhotoID: nil,
                                                   coverData: crops[pk])
                }
            }
        }

        let palettePhotos = Array(highlights.prefix(10))
        return PersonInsight.make(photoCount: max(0, total - videos),
                                  videoCount: videos,
                                  firstDate: earliest,
                                  lastDate: latest,
                                  years: years,
                                  places: places,
                                  periods: PersonInsight.periods(fromHourCounts: hourCounts),
                                  companions: companions,
                                  highlights: highlights,
                                  palettePhotos: palettePhotos)
    }

    // MARK: - 年 / 月总览

    func yearBuckets(_ query: SystemQuery, sampleLimit: Int = 4) -> [PhotoPeriodBucket] {
        // 直连模式下年份计数来自后台按月聚合的快照，样本按年份范围查询。
        if direct != nil { return directYearBuckets(query, sampleLimit: sampleLimit) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let direction = overviewDirection(query)
        let period = "strftime('%Y', created, 'unixepoch', 'localtime')"
        let sql = """
            SELECT * FROM (
                SELECT assets.*, \(period) AS period_key,
                       COUNT(*) OVER (PARTITION BY \(period)) AS period_count,
                       ROW_NUMBER() OVER (PARTITION BY \(period)
                                          ORDER BY assets.created \(direction), assets.uuid \(direction)) AS rn
                FROM \(from) WHERE \(whereSQL)
            ) WHERE rn <= \(sampleLimit)
            ORDER BY period_key \(direction), created \(direction), uuid \(direction)
            """
        guard let rows = try? database.query(sql, fromBinds + binds) else { return [] }
        var order: [String] = []
        var samples: [String: [PhotoItem]] = [:]
        var counts: [String: Int] = [:]
        var dates: [String: Date] = [:]
        for row in rows {
            guard let key = row["period_key"]?.string, let photo = photo(from: row) else { continue }
            if samples[key] == nil {
                order.append(key)
                counts[key] = row["period_count"]?.int ?? 0
                dates[key] = photo.capturedAt
            }
            samples[key, default: []].append(photo)
        }
        return order.compactMap { key in
            guard let photos = samples[key], let date = dates[key] else { return nil }
            return PhotoPeriodBucket(id: key,
                                     title: DateText.yearFormatter.string(from: date),
                                     count: counts[key] ?? photos.count,
                                     photos: photos,
                                     capturedAt: date)
        }
    }

    func monthGroups(_ query: SystemQuery, sampleLimit: Int = 4) -> [PhotoMonthGroup] {
        if direct != nil { return directMonthGroups(query, sampleLimit: sampleLimit) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let direction = overviewDirection(query)
        let month = "strftime('%Y-%m', created, 'unixepoch', 'localtime')"
        let day = "strftime('%Y-%m-%d', created, 'unixepoch', 'localtime')"
        let sql = """
            SELECT * FROM (
                SELECT assets.*, \(month) AS month_key, \(day) AS day_key,
                       COUNT(*) OVER (PARTITION BY \(day)) AS day_count,
                       COUNT(*) OVER (PARTITION BY \(month)) AS month_count,
                       ROW_NUMBER() OVER (PARTITION BY \(day)
                                          ORDER BY assets.created \(direction), assets.uuid \(direction)) AS rn
                FROM \(from) WHERE \(whereSQL)
            ) WHERE rn <= \(sampleLimit)
            ORDER BY month_key \(direction), day_key \(direction), created \(direction), uuid \(direction)
            """
        guard let rows = try? database.query(sql, fromBinds + binds) else { return [] }

        struct MonthDraft {
            var order: [String] = []
            var samples: [String: [PhotoItem]] = [:]
            var counts: [String: Int] = [:]
            var firstDates: [String: Date] = [:]
        }
        var monthOrder: [String] = []
        var drafts: [String: MonthDraft] = [:]
        var monthCounts: [String: Int] = [:]
        var monthDates: [String: Date] = [:]

        for row in rows {
            guard let monthKey = row["month_key"]?.string,
                  let dayKey = row["day_key"]?.string,
                  let photo = photo(from: row) else { continue }
            if drafts[monthKey] == nil {
                monthOrder.append(monthKey)
                drafts[monthKey] = MonthDraft()
                monthCounts[monthKey] = row["month_count"]?.int ?? 0
                monthDates[monthKey] = photo.capturedAt
            }
            if drafts[monthKey]?.samples[dayKey] == nil {
                drafts[monthKey]?.order.append(dayKey)
                drafts[monthKey]?.counts[dayKey] = row["day_count"]?.int ?? 0
                drafts[monthKey]?.firstDates[dayKey] = photo.capturedAt
            }
            drafts[monthKey]?.samples[dayKey, default: []].append(photo)
        }

        let calendar = Calendar.current
        return monthOrder.compactMap { monthKey in
            guard let draft = drafts[monthKey], let monthDate = monthDates[monthKey] else { return nil }
            let days = draft.order.compactMap { dayKey -> PhotoDayBucket? in
                guard let photos = draft.samples[dayKey], let date = draft.firstDates[dayKey] else { return nil }
                let dayNumber = calendar.component(.day, from: date)
                return PhotoDayBucket(id: dayKey,
                                      title: "\(dayNumber)日",
                                      count: draft.counts[dayKey] ?? photos.count,
                                      photos: photos,
                                      capturedAt: date)
            }
            return PhotoMonthGroup(id: monthKey,
                                   title: DateText.monthFormatter.string(from: monthDate),
                                   count: monthCounts[monthKey] ?? days.reduce(0) { $0 + $1.count },
                                   days: days)
        }
    }

    // MARK: - SQL 片段

    private func fromFragment(_ query: SystemQuery) -> (String, [Any?]) {
        switch query.scope {
        case .album(let id):
            return ("assets JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = \(id)", [])
        case .person(let id):
            return ("assets JOIN person_assets pa ON pa.asset = assets.uuid AND pa.person = \(id)", [])
        default:
            return ("assets", [])
        }
    }

    /// 未被隐藏、未被删除（考虑拾光补充元数据对收藏 / 隐藏的覆盖）。
    private func activePredicate(_ query: SystemQuery) -> String {
        let hiddenAdds = inList(query.hiddenAdds)
        let hiddenRemoves = inList(query.hiddenRemoves)
        return """
            (trashed IS NULL AND ((hidden = 0 AND assets.uuid NOT IN (\(hiddenAdds)))
             OR (hidden = 1 AND assets.uuid IN (\(hiddenRemoves)))))
            """
    }

    private func whereClause(_ query: SystemQuery) -> (String, [Any?]) {
        var clauses: [String] = []
        var binds: [Any?] = []
        let active = activePredicate(query)
        let favoriteAdds = inList(query.favoriteAdds)
        let favoriteRemoves = inList(query.favoriteRemoves)
        let hiddenAdds = inList(query.hiddenAdds)
        let hiddenRemoves = inList(query.hiddenRemoves)

        switch query.scope {
        case .all, .album, .person:
            clauses.append(active)
        case .favorites:
            clauses.append("""
                \(active) AND ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        case .videos:
            clauses.append("\(active) AND isvideo = 1")
        case .screenshots:
            clauses.append("\(active) AND mediakind = 'screenshot'")
        case .hidden:
            clauses.append("""
                (trashed IS NULL AND ((hidden = 1 AND assets.uuid NOT IN (\(hiddenRemoves)))
                 OR assets.uuid IN (\(hiddenAdds))))
                """)
        case .trash:
            clauses.append("trashed IS NOT NULL")
        case .portraits:
            clauses.append("\(active) AND depth > 0 AND isvideo = 0")
        case .selfies:
            clauses.append("\(active) AND mediakind = 'selfie' AND isvideo = 0")
        case .livePhotos:
            clauses.append("\(active) AND islive = 1")
        case .panoramas:
            clauses.append("\(active) AND mediakind = 'panorama'")
        case .longExposures, .cinematics:
            // Photos.sqlite 没有稳定字段，具体集合由 PhotoKit 智能相簿的 includeIDs 提供。
            clauses.append(active)
        case .spatial:
            // 本地索引没有空间媒体字段；空间照片只在系统图库直连模式显示。
            clauses.append("0")
        case .timelapses:
            clauses.append("\(active) AND istimelapse = 1")
        case .bursts:
            // 按组展示代表照片：多成员组取键照片（burstpick），
            // 单成员组没有键照片标记、自身即代表（与官方「照片」口径一致）。
            clauses.append("""
                \(active) AND isburst = 1 AND (burstpick = 1
                 OR burstuuid IN (SELECT s.burstuuid FROM assets s
                                  WHERE s.isburst = 1
                                  GROUP BY s.burstuuid HAVING COUNT(*) = 1))
                """)
        case .slowMotion:
            clauses.append("\(active) AND isslow = 1")
        case .screenRecordings:
            clauses.append("\(active) AND isscreenrec = 1")
        case .animated:
            clauses.append("\(active) AND isanimated = 1")
        case .raws:
            clauses.append("\(active) AND israw = 1")
        case .edited:
            clauses.append("\(active) AND isedited = 1")
        case .recentlyViewed:
            let cutoff = (query.viewedCutoff ?? Self.recentlyViewedCutoff).timeIntervalSince1970
            clauses.append("\(active) AND viewedat >= \(cutoff)")
        case .duplicates:
            clauses.append("\(active) AND duplicate = 1")
        case .recentlySaved:
            let cutoff = (query.savedCutoff ?? Self.recentlySavedCutoff).timeIntervalSince1970
            clauses.append("\(active) AND added >= \(cutoff)")
        case .imports:
            clauses.append("\(active) AND isdeviceimport = 1")
        case .importSession:
            // 本地索引没有官方导入会话编号；只在系统图库直连模式使用。
            clauses.append("0")
        case .revisit:
            let captureCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge).timeIntervalSince1970
            let viewCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitViewAge).timeIntervalSince1970
            clauses.append("""
                \(active) AND created <= \(captureCutoff)
                AND (viewedat IS NULL OR viewedat < \(viewCutoff))
                """)
        case .withLocation:
            clauses.append("\(active) AND haslocation = 1")
        case .folder(let id):
            let albumIDs = albumIDs(inFolder: id)
            let list = inList(albumIDs.map(String.init))
            clauses.append("""
                \(active) AND assets.uuid IN (SELECT asset FROM album_assets WHERE album IN (\(list)))
                """)
        }

        if query.onlyLocated {
            clauses.append("haslocation = 1")
        }

        switch query.filter {
        case .all:
            break
        case .favorites:
            clauses.append("""
                ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        case .edited:
            clauses.append("isedited = 1")
        case .photos:
            clauses.append("isvideo = 0")
        case .videos:
            clauses.append("isvideo = 1")
        case .screenshots:
            clauses.append("mediakind = 'screenshot'")
        case .mine:
            clauses.append("(make IS NOT NULL OR model IS NOT NULL)")
        case .notInAlbum:
            clauses.append("inalbum = 0")
        }

        if let start = query.startDate {
            clauses.append("created >= \(start.timeIntervalSince1970)")
        }
        if let end = query.endDate {
            clauses.append("created < \(end.timeIntervalSince1970)")
        }
        if query.onlyFavorites {
            clauses.append("""
                ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        }
        if query.onlyVideos { clauses.append("isvideo = 1") }
        if query.onlyPhotos { clauses.append("isvideo = 0") }
        if query.onlyScreenshots { clauses.append("mediakind = 'screenshot'") }
        if query.onlyLivePhotos { clauses.append("islive = 1") }
        if query.onlyEdited { clauses.append("isedited = 1") }
        if let keywordIDs = query.overlayKeywordIDs {
            clauses.append("assets.uuid IN (\(inList(keywordIDs)))")
        }
        if let includeIDs = query.includeIDs {
            clauses.append("assets.uuid IN (\(inList(includeIDs)))")
        }
        for token in query.tokens where !token.isEmpty {
            let value = "%\(token.lowercased())%"
            clauses.append("""
                (lower(filename) LIKE ? OR lower(originalname) LIKE ?
                 OR lower(COALESCE(title, '')) LIKE ?
                 OR lower(COALESCE(placecountry, '') || ' ' || COALESCE(placeprovince, '') || ' '
                          || COALESCE(placecity, '') || ' ' || COALESCE(placedistrict, '') || ' '
                          || COALESCE(placepoi, '')) LIKE ?
                 OR lower(COALESCE(make, '') || ' ' || COALESCE(model, '') || ' '
                          || COALESCE(lens, '')) LIKE ?)
                """)
            binds.append(contentsOf: [value, value, value, value, value])
        }
        return (clauses.joined(separator: " AND "), binds)
    }

    /// 官方相簿手动顺序（`ZGENERICALBUM` 关联表的 position）；其它排序字段由用户选择决定。
    private func orderExpression(_ query: SystemQuery) -> String {
        if case .album = query.scope, query.manualOrder {
            return "aa.position"
        }
        switch query.sortKey {
        case .capturedAt: return "assets.created"
        case .addedAt: return "assets.added"
        case .title: return "COALESCE(NULLIF(assets.title, ''), assets.originalname) COLLATE NOCASE"
        case .filename: return "assets.filename COLLATE NOCASE"
        case .fileSize: return "assets.filesize"
        case .kind: return "assets.mediakind COLLATE NOCASE"
        case .camera: return "COALESCE(NULLIF(assets.model, ''), NULLIF(assets.make, ''), '') COLLATE NOCASE"
        case .place: return "COALESCE(NULLIF(assets.placecity, ''), NULLIF(assets.placeprovince, ''), NULLIF(assets.placecountry, ''), '') COLLATE NOCASE"
        case .duration: return "COALESCE(assets.duration, 0)"
        }
    }

    private func overviewDirection(_ query: SystemQuery) -> String {
        if query.sortKey == .capturedAt {
            return query.ascending ? "ASC" : "DESC"
        }
        return "DESC"
    }

    private func sortValue(of id: UUID, in query: SystemQuery) -> (value: Any, isText: Bool)? {
        if case .album = query.scope, query.manualOrder {
            guard let row = try? database.query("""
                SELECT aa.position AS v FROM album_assets aa WHERE aa.asset = ?
                """, [id.uuidString]).first,
                let value = row["v"] else { return nil }
            return (value.int64 ?? 0, false)
        }
        let expr = orderExpression(query)
        guard let row = try? database.query("SELECT \(expr) AS v FROM assets WHERE uuid = ?",
                                            [id.uuidString]).first,
              let value = row["v"] else { return nil }
        switch value {
        case .null: return (0, false)
        case .integer(let number): return (number, false)
        case .real(let number): return (number, false)
        case .text(let text): return (text, true)
        case .blob: return (0, false)
        }
    }

    private static var recentlySavedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    private static var recentlyViewedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
        "rw2", "pef", "srw", "raw", "3fr", "erf", "mef", "mos", "iiq", "rwl"
    ]

    func inList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "''" }
        return values.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            .joined(separator: ",")
    }

    // MARK: - 行 → PhotoItem

    func photo(from row: [String: SQLiteValue]) -> PhotoItem? {
        guard let uuidString = row["uuid"]?.string,
              let uuid = UUID(uuidString: uuidString),
              let filename = row["filename"]?.string else { return nil }
        let kind = MediaKind(rawValue: row["mediakind"]?.string ?? "photo") ?? .photo
        let originalName = row["originalname"]?.string ?? filename
        var item = PhotoItem(
            id: uuid,
            filename: filename,
            editedFilename: nil,
            originalName: originalName,
            capturedAt: Date(timeIntervalSince1970: row["created"]?.double ?? 0),
            addedAt: Date(timeIntervalSince1970: row["added"]?.double ?? 0),
            pixelWidth: row["width"]?.int ?? 0,
            pixelHeight: row["height"]?.int ?? 0,
            fileSize: row["filesize"]?.int64 ?? 0,
            kind: kind
        )
        item.isFavorite = (row["favorite"]?.int ?? 0) == 1
        item.isHidden = (row["hidden"]?.int ?? 0) == 1
        item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
        item.isDuplicateItem = (row["duplicate"]?.int ?? 0) == 1
        item.isLivePhoto = (row["islive"]?.int ?? 0) == 1
        item.isBurstItem = (row["isburst"]?.int ?? 0) == 1
        item.burstGroupID = row["burstuuid"]?.string
        item.isBurstKeyPhoto = (row["burstpick"]?.int ?? 0) == 1
        item.isSlowMotion = (row["isslow"]?.int ?? 0) == 1
        item.isTimelapse = (row["istimelapse"]?.int ?? 0) == 1
        item.isCinematic = (row["iscinematic"]?.int ?? 0) == 1
        item.isSpatial = (row["isspatial"]?.int ?? 0) == 1
        item.isScreenRecording = (row["isscreenrec"]?.int ?? 0) == 1
        item.isAnimated = (row["isanimated"]?.int ?? 0) == 1
        item.isDeviceImport = (row["isdeviceimport"]?.int ?? 0) == 1
        item.duration = row["duration"]?.double
        item.latitude = row["latitude"]?.double
        item.longitude = row["longitude"]?.double
        item.placeCountry = row["placecountry"]?.string
        item.placeProvince = row["placeprovince"]?.string
        item.placeCity = row["placecity"]?.string
        item.placeDistrict = row["placedistrict"]?.string
        item.placePOI = row["placepoi"]?.string
        item.make = row["make"]?.string
        item.model = row["model"]?.string
        item.lens = row["lens"]?.string
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
        if let title = row["title"]?.string, !title.isEmpty {
            item.title = title
        }
        if let viewed = row["viewedat"]?.double {
            item.viewedAt = Date(timeIntervalSince1970: viewed)
        }
        if let edited = row["editedat"]?.double {
            item.editedAt = Date(timeIntervalSince1970: edited)
        }
        if let trashed = row["trashed"]?.double {
            item.deletedAt = Date(timeIntervalSince1970: trashed)
        }
        item.source = .system
        item.systemOriginalPath = row["origpath"]?.string
        item.systemThumbnailPath = row["thumbpath"]?.string
        item.livePhotoVideoPath = row["livevideopath"]?.string
        return item
    }

    // MARK: - 辅助

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

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private struct AlbumAssetJoin {
        let table: String
        let albumColumn: String
        let assetColumn: String
        let orderColumn: String?
    }

    private static func findAlbumAssetJoin(_ db: SQLiteDatabase) -> AlbumAssetJoin? {
        guard let tables = try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") else {
            return nil
        }
        for tableRow in tables {
            guard let table = tableRow["name"]?.string, table.hasPrefix("Z_") else { continue }
            guard let columns = try? db.query("PRAGMA table_info(\"\(table)\")") else { continue }
            let names = columns.compactMap { $0["name"]?.string }
            guard let assetColumn = names.first(where: { $0 == "Z_3ASSETS" }),
                  let albumColumn = names.first(where: { name in
                      guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMS") else { return false }
                      let middle = name.dropFirst(2).dropLast(6)
                      return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
                  }) else { continue }
            let orderColumn = names.first(where: { $0 == "Z_FOK_3ASSETS" })
            return AlbumAssetJoin(table: table,
                                  albumColumn: albumColumn,
                                  assetColumn: assetColumn,
                                  orderColumn: orderColumn)
        }
        return nil
    }
}
