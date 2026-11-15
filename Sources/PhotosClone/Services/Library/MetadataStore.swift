import Foundation

/// 本地图库的元数据存储（SQLite）。系统「照片」图库只读，不写入这里。
final class MetadataStore {
    let db: SQLiteDatabase
    let queue = DispatchQueue(label: "com.baymax.photosclone.metadata")
    private var pendingData: LibraryData?
    private var isWriting = false

    init(url: URL) throws {
        db = try SQLiteDatabase(path: url.path, readonly: false)
        try migrateSchema()
        try migrateLegacyJSONIfNeeded()
    }

    // MARK: - Public API

    func loadLibrary() -> LibraryData {
        queue.sync {
            (try? readLibrary()) ?? LibraryData()
        }
    }

    func save(_ data: LibraryData) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingData = data
            guard !self.isWriting else { return }
            self.isWriting = true
            while let next = self.pendingData {
                self.pendingData = nil
                do {
                    try self.write(next)
                } catch {
                    FileHandle.standardError.write(Data("metadata save failed: \(error)\n".utf8))
                }
            }
            self.isWriting = false
        }
    }

    func flush() {
        queue.sync {
            while let next = pendingData {
                pendingData = nil
                try? write(next)
            }
        }
    }

    /// 增量写入导入产生的新照片，避免每批都全量重写 assets 表。
    func appendPhotos(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.db.transaction {
                    for item in items where item.source != .system {
                        try self.insertAsset(item)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("metadata append failed: \(error)\n".utf8))
            }
        }
    }

    func setting(_ key: String) -> String? {
        queue.sync {
            (try? db.query("SELECT value FROM settings WHERE key = ?", [key]).first?["value"]?.string) ?? nil
        }
    }

    func setSetting(_ key: String, _ value: String?) {
        queue.sync {
            if let value {
                try? db.execute("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", [key, value])
            } else {
                try? db.execute("DELETE FROM settings WHERE key = ?", [key])
            }
        }
    }

    // MARK: - 系统照片的补充元数据

    /// 官方「照片」图库照片的拾光侧覆盖值；nil 表示沿用 Apple 自己的元数据。
    struct AssetOverlay {
        var isFavorite: Bool?
        var isHidden: Bool?
        var keywords: [String]?
        var title: String?
        var viewedAt: Date?

        var isEmpty: Bool {
            isFavorite == nil && isHidden == nil && keywords == nil && title == nil && viewedAt == nil
        }
    }

    func loadOverlays() -> [UUID: AssetOverlay] {
        queue.sync {
            let rows = (try? db.query("SELECT * FROM asset_overlays")) ?? []
            var result: [UUID: AssetOverlay] = [:]
            for row in rows {
                guard let idString = row["asset_id"]?.string, let id = UUID(uuidString: idString) else { continue }
                var overlay = AssetOverlay()
                overlay.isFavorite = row["is_favorite"]?.int64.map { $0 != 0 }
                overlay.isHidden = row["is_hidden"]?.int64.map { $0 != 0 }
                if let json = row["keywords"]?.string, let data = json.data(using: .utf8) {
                    overlay.keywords = try? JSONDecoder().decode([String].self, from: data)
                }
                overlay.title = row["title"]?.string
                overlay.viewedAt = row["viewed_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                result[id] = overlay
            }
            return result
        }
    }

    func saveOverlay(_ id: UUID, _ overlay: AssetOverlay) {
        queue.sync {
            guard !overlay.isEmpty else {
                try? db.execute("DELETE FROM asset_overlays WHERE asset_id = ?", [id.uuidString])
                return
            }
            let keywords: String?
            if let list = overlay.keywords, let data = try? JSONEncoder().encode(list) {
                keywords = String(data: data, encoding: .utf8)
            } else {
                keywords = nil
            }
            try? db.execute("""
                INSERT OR REPLACE INTO asset_overlays
                (asset_id, is_favorite, is_hidden, keywords, title, viewed_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [
                    id.uuidString,
                    overlay.isFavorite.map { $0 ? 1 : 0 },
                    overlay.isHidden.map { $0 ? 1 : 0 },
                    keywords,
                    overlay.title,
                    overlay.viewedAt?.timeIntervalSince1970,
                    Date().timeIntervalSince1970
                ])
        }
    }

    // MARK: - 智能分析（场景标签 / OCR / 特征向量）

    func loadAnalysisIndex() -> [(id: UUID, labels: String, text: String)] {
        queue.sync {
            guard let rows = try? db.query("SELECT asset_id, labels, text FROM asset_analysis") else { return [] }
            return rows.compactMap { row in
                guard let idString = row["asset_id"]?.string,
                      let id = UUID(uuidString: idString) else { return nil }
                return (id, row["labels"]?.string ?? "", row["text"]?.string ?? "")
            }
        }
    }

    func saveAnalysis(_ entries: [(id: UUID, labels: String, text: String, feature: Data?)]) {
        guard !entries.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            try? self.db.transaction {
                for entry in entries {
                    try self.db.execute("""
                        INSERT OR REPLACE INTO asset_analysis (asset_id, labels, text, feature, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, [entry.id.uuidString, entry.labels, entry.text, entry.feature, now])
                }
            }
        }
    }

    func removeAnalysis(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                try? self.db.execute("DELETE FROM asset_analysis WHERE asset_id = ?", [id.uuidString])
            }
        }
    }

    func feature(for id: UUID) -> Data? {
        queue.sync {
            (try? db.query("SELECT feature FROM asset_analysis WHERE asset_id = ?", [id.uuidString]))?
                .first?["feature"]?.data
        }
    }

    /// 全部已分析照片的特征向量；`limit` 用于限制聚类规模（相似分组是 O(n·组数)）。
    func allFeatures(limit: Int = 3000) -> [(id: UUID, feature: Data)] {
        queue.sync {
            guard let rows = try? db.query("""
                SELECT asset_id, feature FROM asset_analysis
                WHERE feature IS NOT NULL ORDER BY updated_at DESC LIMIT ?
                """, [limit]) else { return [] }
            return rows.compactMap { row in
                guard let idString = row["asset_id"]?.string,
                      let id = UUID(uuidString: idString),
                      let feature = row["feature"]?.data, !feature.isEmpty else { return nil }
                return (id, feature)
            }
        }
    }

    /// 按特征向量找相似照片（余弦相似度，向量在写入时已归一化）。
    func similarPhotos(to feature: Data, excluding id: UUID,
                       limit: Int = 80, minimumScore: Float = 0.72) -> [UUID] {
        queue.sync {
            guard let rows = try? db.query(
                "SELECT asset_id, feature FROM asset_analysis WHERE feature IS NOT NULL"
            ) else { return [] }
            let source = feature.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !source.isEmpty else { return [] }
            var scored: [(UUID, Float)] = []
            for row in rows {
                guard let idString = row["asset_id"]?.string,
                      let targetID = UUID(uuidString: idString),
                      targetID != id,
                      let blob = row["feature"]?.data, !blob.isEmpty else { continue }
                let vector = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard vector.count == source.count else { continue }
                var score: Float = 0
                for index in 0..<vector.count {
                    score += source[index] * vector[index]
                }
                if score >= minimumScore {
                    scored.append((targetID, score))
                }
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
    }

    // MARK: - 人物聚类

    func loadPeople() -> [LocalPerson] {
        queue.sync {
            guard let rows = try? db.query("SELECT * FROM people ORDER BY face_count DESC") else { return [] }
            var members: [String: [UUID]] = [:]
            if let assetRows = try? db.query("SELECT * FROM person_assets") {
                for row in assetRows {
                    guard let personID = row["person_id"]?.string,
                          let assetID = row["asset_id"]?.string.flatMap({ UUID(uuidString: $0) }) else { continue }
                    members[personID, default: []].append(assetID)
                }
            }
            return rows.compactMap { row -> LocalPerson? in
                guard let idString = row["id"]?.string,
                      let id = UUID(uuidString: idString),
                      let name = row["name"]?.string else { return nil }
                let assetIDs = members[idString] ?? []
                guard !assetIDs.isEmpty else { return nil }
                return LocalPerson(id: id,
                                   name: name,
                                   assetIDs: assetIDs,
                                   coverImageData: row["cover"]?.data,
                                   faceCount: row["face_count"]?.int ?? 0,
                                   centroid: Self.decodeCentroid(row["centroid"]?.data))
            }
        }
    }

    func savePeople(_ people: [LocalPerson]) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                try self.db.execute("DELETE FROM people;")
                try self.db.execute("DELETE FROM person_assets;")
                for person in people {
                    try self.db.execute("""
                        INSERT OR REPLACE INTO people (id, name, face_count, cover, centroid, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, [
                            person.id.uuidString,
                            person.name,
                            person.faceCount,
                            person.coverImageData,
                            Self.encodeCentroid(person.centroid),
                            Date().timeIntervalSince1970
                        ])
                    for assetID in person.assetIDs {
                        try self.db.execute("""
                            INSERT OR REPLACE INTO person_assets (person_id, asset_id) VALUES (?, ?)
                            """, [person.id.uuidString, assetID.uuidString])
                    }
                }
            }
        }
    }

    func loadScannedFaceIDs() -> Set<UUID> {
        queue.sync {
            guard let rows = try? db.query("SELECT asset_id FROM scanned_faces") else { return [] }
            return Set(rows.compactMap { row in
                row["asset_id"]?.string.flatMap { UUID(uuidString: $0) }
            })
        }
    }

    func saveScannedFaceIDs(_ ids: Set<UUID>) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                try self.db.execute("DELETE FROM scanned_faces;")
                for id in ids {
                    try self.db.execute("INSERT OR REPLACE INTO scanned_faces (asset_id) VALUES (?)",
                                        [id.uuidString])
                }
            }
        }
    }

    private static func encodeCentroid(_ vector: [Float]) -> Data? {
        guard !vector.isEmpty else { return nil }
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeCentroid(_ data: Data?) -> [Float] {
        guard let data, !data.isEmpty, data.count % 4 == 0 else { return [] }
        var vector = [Float](repeating: 0, count: data.count / 4)
        vector.withUnsafeMutableBytes { buffer in
            _ = data.copyBytes(to: buffer)
        }
        return vector
    }

    // MARK: - Schema

    private func migrateSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY NOT NULL,
                filename TEXT NOT NULL,
                edited_filename TEXT,
                original_name TEXT NOT NULL,
                captured_at REAL NOT NULL,
                added_at REAL NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                kind TEXT NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL,
                edit_version INTEGER NOT NULL DEFAULT 0,
                duration REAL,
                make TEXT,
                model TEXT,
                lens TEXT,
                focal_length TEXT,
                aperture TEXT,
                shutter_speed TEXT,
                iso TEXT,
                latitude REAL,
                longitude REAL,
                keywords TEXT
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_assets_captured ON assets(captured_at);")
        // 自定义标题：必须先补列，下面的标题索引引用了它（新建库同样要先补，否则索引创建会失败）。
        try addColumnIfNeeded("assets", "title", "TEXT")
        // 大图库分页索引：复合索引末尾带 id，并按排序方向扫描，避免每次翻页都对全表排序。
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_assets_live_captured_id
            ON assets(captured_at, id) WHERE deleted_at IS NULL AND is_hidden = 0;
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_assets_live_added_id
            ON assets(added_at, id) WHERE deleted_at IS NULL AND is_hidden = 0;
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_assets_live_size_id
            ON assets(file_size, id) WHERE deleted_at IS NULL AND is_hidden = 0;
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_assets_live_title_id
            ON assets(COALESCE(NULLIF(title, ''), original_name) COLLATE NOCASE, id)
            WHERE deleted_at IS NULL AND is_hidden = 0;
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_assets_live_filename_id
            ON assets(COALESCE(edited_filename, filename) COLLATE NOCASE, id)
            WHERE deleted_at IS NULL AND is_hidden = 0;
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_assets_added ON assets(added_at);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_assets_deleted ON assets(deleted_at);")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                parent_id TEXT,
                created_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS albums (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                folder_id TEXT,
                created_at REAL NOT NULL,
                cover_asset_id TEXT
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS album_assets (
                album_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (album_id, asset_id)
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_album_assets_album ON album_assets(album_id);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_album_assets_asset ON album_assets(asset_id);")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT
            );
            """)
        // 端侧人脸聚类结果。
        try db.execute("""
            CREATE TABLE IF NOT EXISTS people (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                face_count INTEGER NOT NULL DEFAULT 0,
                cover BLOB,
                centroid BLOB,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS person_assets (
                person_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                PRIMARY KEY (person_id, asset_id)
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS scanned_faces (
                asset_id TEXT PRIMARY KEY NOT NULL
            );
            """)
        // 端侧智能分析：场景标签、OCR 文字与图像特征向量。
        try db.execute("""
            CREATE TABLE IF NOT EXISTS asset_analysis (
                asset_id TEXT PRIMARY KEY NOT NULL,
                labels TEXT,
                text TEXT,
                feature BLOB,
                updated_at REAL NOT NULL
            );
            """)
        // 官方「照片」图库里的照片：拾光的补充元数据（收藏 / 隐藏 / 查看时间 / 关键词 / 标题）。
        // 只写这里，绝不回写 Photos.sqlite；NULL 表示沿用 Apple 自己的值。
        try db.execute("""
            CREATE TABLE IF NOT EXISTS asset_overlays (
                asset_id TEXT PRIMARY KEY NOT NULL,
                is_favorite INTEGER,
                is_hidden INTEGER,
                keywords TEXT,
                title TEXT,
                viewed_at REAL,
                updated_at REAL NOT NULL
            );
            """)
        // 旧库补列：最近查看时间（「值得重看」用）。
        try addColumnIfNeeded("assets", "viewed_at", "REAL")
        try db.execute("PRAGMA user_version = 5;")

        // 地点信息（旧库自动补列）。
        for column in ["place_country", "place_province", "place_city", "place_district", "place_poi"] {
            try addColumnIfNeeded("assets", column, "TEXT")
        }
        // 自定义标题已在建表后补过列（标题索引依赖它）。
        // 编辑配方（旧库自动补列）。
        try addColumnIfNeeded("assets", "edit_recipe", "TEXT")
        // 实况照片配对信息（旧库自动补列）。
        try addColumnIfNeeded("assets", "is_live_photo", "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded("assets", "live_photo_filename", "TEXT")
        // 导入批次（旧库自动补列）：同一批导入的照片共用一个 UUID，用于「导入项目」分组。
        try addColumnIfNeeded("assets", "import_batch_id", "TEXT")
        try addColumnIfNeeded("assets", "live_photo_video_path", "TEXT")
        // 相簿自定义封面（旧库自动补列）。
        try addColumnIfNeeded("albums", "cover_asset_id", "TEXT")
    }

    private func addColumnIfNeeded(_ table: String, _ column: String, _ type: String) throws {
        let columns = try db.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string }
        guard !columns.contains(column) else { return }
        try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
    }

    private func migrateLegacyJSONIfNeeded() throws {
        // Library.json 是旧版未绑定图库时的全局数据；已打开某个图库时，它不属于这个库，
        // 不能自动迁入（否则新打开的图库会凭空多出别的图库的照片）。
        guard LibraryPaths.containerLibraryURL == nil else { return }
        let assetCount = try db.query("SELECT COUNT(*) AS c FROM assets").first?["c"]?.int64 ?? 0
        let albumCount = try db.query("SELECT COUNT(*) AS c FROM albums").first?["c"]?.int64 ?? 0
        guard assetCount == 0, albumCount == 0 else { return }
        guard let data = try? Data(contentsOf: LibraryPaths.libraryFile),
              let legacy = try? JSONDecoder().decode(LibraryData.self, from: data) else {
            return
        }
        try write(legacy)
        try? db.execute("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", ["legacy_json_migrated", "1"])
        let migratedURL = LibraryPaths.libraryFile.appendingPathExtension("migrated")
        try? FileManager.default.moveItem(at: LibraryPaths.libraryFile, to: migratedURL)
        FileHandle.standardError.write(Data("Migrated Library.json to SQLite (\(legacy.photos.count) assets)\n".utf8))
    }

    // MARK: - Read

    private func readLibrary() throws -> LibraryData {
        var data = LibraryData()

        let folderRows = try db.query("SELECT * FROM folders ORDER BY name COLLATE NOCASE")
        data.folders = folderRows.compactMap { row in
            guard let idString = row["id"]?.string, let id = UUID(uuidString: idString),
                  let name = row["name"]?.string else { return nil }
            return AlbumFolder(id: id,
                               name: name,
                               parentID: row["parent_id"]?.string.flatMap { UUID(uuidString: $0) },
                               createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0))
        }

        var albums: [Album] = []
        let albumRows = try db.query("SELECT * FROM albums ORDER BY name COLLATE NOCASE")
        let assetRows = try db.query("SELECT * FROM album_assets ORDER BY album_id, position")
        var members: [String: [UUID]] = [:]
        for row in assetRows {
            guard let albumID = row["album_id"]?.string,
                  let assetIDString = row["asset_id"]?.string,
                  let assetID = UUID(uuidString: assetIDString) else { continue }
            members[albumID, default: []].append(assetID)
        }
        for row in albumRows {
            guard let idString = row["id"]?.string, let id = UUID(uuidString: idString),
                  let name = row["name"]?.string else { continue }
            var album = Album(id: id,
                              name: name,
                              createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                              folderID: row["folder_id"]?.string.flatMap { UUID(uuidString: $0) })
            album.coverPhotoID = row["cover_asset_id"]?.string.flatMap { UUID(uuidString: $0) }
            album.photoIDs = members[idString] ?? []
            albums.append(album)
        }
        data.albums = albums

        let photoRows = try db.query("SELECT * FROM assets ORDER BY captured_at DESC")
        var photos: [PhotoItem] = []
        photos.reserveCapacity(photoRows.count)
        for row in photoRows {
            if let photo = photo(from: row) {
                photos.append(photo)
            }
        }

        // 不按文件是否存在过滤：外置盘未挂载、文件被外部删除或路径临时不可达时，
        // 过滤出的空结果一旦被 save() 写回，整库元数据就被清空了。
        // 缺失文件的条目交给缩略图占位展示，用户仍然可以自行删除。
        data.photos = photos
        return data
    }

    func photo(from row: [String: SQLiteValue]) -> PhotoItem? {
        guard let idString = row["id"]?.string, let id = UUID(uuidString: idString),
              let filename = row["filename"]?.string,
              let originalName = row["original_name"]?.string,
              let kindString = row["kind"]?.string else {
            return nil
        }

        var item = PhotoItem(
            id: id,
            filename: filename,
            editedFilename: row["edited_filename"]?.string,
            originalName: originalName,
            capturedAt: Date(timeIntervalSince1970: row["captured_at"]?.double ?? 0),
            addedAt: Date(timeIntervalSince1970: row["added_at"]?.double ?? 0),
            pixelWidth: row["pixel_width"]?.int ?? 0,
            pixelHeight: row["pixel_height"]?.int ?? 0,
            fileSize: row["file_size"]?.int64 ?? 0,
            kind: MediaKind(rawValue: kindString) ?? .photo
        )
        item.isFavorite = row["is_favorite"]?.bool ?? false
        item.isHidden = row["is_hidden"]?.bool ?? false
        item.title = row["title"]?.string
        item.editRecipe = row["edit_recipe"]?.string
        item.livePhotoFilename = row["live_photo_filename"]?.string
        item.livePhotoVideoPath = row["live_photo_video_path"]?.string
        item.isLivePhoto = (row["is_live_photo"]?.bool ?? false)
            || item.livePhotoFilename != nil
            || item.livePhotoVideoPath != nil
        item.importBatchID = row["import_batch_id"]?.string.flatMap { UUID(uuidString: $0) }
        item.deletedAt = row["deleted_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        item.viewedAt = row["viewed_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        item.editVersion = row["edit_version"]?.int ?? 0
        item.duration = row["duration"]?.double
        item.make = row["make"]?.string
        item.model = row["model"]?.string
        item.lens = row["lens"]?.string
        item.focalLength = row["focal_length"]?.string
        item.aperture = row["aperture"]?.string
        item.shutterSpeed = row["shutter_speed"]?.string
        item.iso = row["iso"]?.string
        item.latitude = row["latitude"]?.double
        item.longitude = row["longitude"]?.double
        item.placeCountry = row["place_country"]?.string
        item.placeProvince = row["place_province"]?.string
        item.placeCity = row["place_city"]?.string
        item.placeDistrict = row["place_district"]?.string
        item.placePOI = row["place_poi"]?.string
        if let keywordsString = row["keywords"]?.string,
           let keywordsData = keywordsString.data(using: .utf8) {
            item.keywords = try? JSONDecoder().decode([String].self, from: keywordsData)
        }
        return item
    }

    // MARK: - Write

    private func write(_ data: LibraryData) throws {
        try db.transaction {
            try db.execute("DELETE FROM album_assets;")
            try db.execute("DELETE FROM assets;")
            try db.execute("DELETE FROM albums;")
            try db.execute("DELETE FROM folders;")

            for folder in data.folders {
                try db.execute("""
                    INSERT INTO folders (id, name, parent_id, created_at) VALUES (?, ?, ?, ?)
                    """, [
                        folder.id.uuidString,
                        folder.name,
                        folder.parentID?.uuidString,
                        folder.createdAt.timeIntervalSince1970
                    ])
            }

            for album in data.albums {
                try db.execute("""
                    INSERT INTO albums (id, name, folder_id, created_at, cover_asset_id) VALUES (?, ?, ?, ?, ?)
                    """, [
                        album.id.uuidString,
                        album.name,
                        album.folderID?.uuidString,
                        album.createdAt.timeIntervalSince1970,
                        album.coverPhotoID?.uuidString
                    ])
                for (index, assetID) in album.photoIDs.enumerated() {
                    try db.execute("""
                        INSERT OR REPLACE INTO album_assets (album_id, asset_id, position) VALUES (?, ?, ?)
                        """, [album.id.uuidString, assetID.uuidString, index])
                }
            }

            for photo in data.photos where photo.source != .system {
                try insertAsset(photo)
            }
        }
    }

    private func insertAsset(_ photo: PhotoItem) throws {
        let keywords: String?
        if let tags = photo.keywords, !tags.isEmpty,
           let encoded = try? JSONEncoder().encode(tags) {
            keywords = String(data: encoded, encoding: .utf8)
        } else {
            keywords = nil
        }
        try db.execute("""
            INSERT OR REPLACE INTO assets (
                id, filename, edited_filename, original_name, title, captured_at, added_at,
                pixel_width, pixel_height, file_size, kind, is_favorite, is_hidden,
                deleted_at, edit_version, duration, make, model, lens, focal_length,
                aperture, shutter_speed, iso, latitude, longitude, keywords,
                place_country, place_province, place_city, place_district, place_poi,
                edit_recipe, is_live_photo, live_photo_filename, live_photo_video_path,
                import_batch_id, viewed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                photo.id.uuidString,
                photo.filename,
                photo.editedFilename,
                photo.originalName,
                photo.title,
                photo.capturedAt.timeIntervalSince1970,
                photo.addedAt.timeIntervalSince1970,
                photo.pixelWidth,
                photo.pixelHeight,
                photo.fileSize,
                photo.kind.rawValue,
                photo.isFavorite,
                photo.isHidden,
                photo.deletedAt?.timeIntervalSince1970,
                photo.editVersion,
                photo.duration,
                photo.make,
                photo.model,
                photo.lens,
                photo.focalLength,
                photo.aperture,
                photo.shutterSpeed,
                photo.iso,
                photo.latitude,
                photo.longitude,
                keywords,
                photo.placeCountry,
                photo.placeProvince,
                photo.placeCity,
                photo.placeDistrict,
                photo.placePOI,
                photo.editRecipe,
                photo.isLivePhoto,
                photo.livePhotoFilename,
                photo.livePhotoVideoPath,
                photo.importBatchID?.uuidString,
                photo.viewedAt?.timeIntervalSince1970
            ])
    }

    /// 记录一次查看（只更新单行，避免为一次打开重写整个资产表）。
    func setViewedAt(_ id: UUID, date: Date) {
        queue.async { [weak self] in
            try? self?.db.execute("UPDATE assets SET viewed_at = ? WHERE id = ?",
                                  [date.timeIntervalSince1970, id.uuidString])
        }
    }
}
