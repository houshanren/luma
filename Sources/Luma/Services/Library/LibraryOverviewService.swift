import Foundation

/// 多图库总览的只读读取：系统「照片」图库与其它 App 图库都从这里进入。
/// 视图不再直接打开 `Photos.sqlite` / `Luma.sqlite`。
enum LibraryOverviewService {
    struct NativeLoad {
        let summary: LibraryOverviewSummary
        let items: [LibraryOverviewItem]
        let favorites: [LibraryOverviewItem]
    }

    /// 直连一个系统照片图库：读合计、相簿 / 文件夹数量与最近照片。
    static func loadNative(path: String,
                           name: String,
                           isAppContainer: Bool,
                           photoLimit: Int,
                           favoriteLimit: Int) -> NativeLoad? {
        let url = URL(fileURLWithPath: path)
        guard let index = SystemIndex.openDirect(libraryURL: url, withSearchIndex: false) else { return nil }
        let totals = index.summary(SystemQuery())
        let meta = SystemIndex.albumMetadata(libraryURL: url)
        let photos = index.page(SystemQuery(), offset: 0, limit: photoLimit)
        let favorites = index.page(SystemQuery(scope: .favorites), offset: 0, limit: favoriteLimit)
        let dbURL = url.appendingPathComponent("database/Photos.sqlite")
        let updated = (try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date

        let summary = LibraryOverviewSummary(id: path,
                                            name: name,
                                            path: path,
                                            isNative: true,
                                            isAppContainer: isAppContainer,
                                            photos: max(0, totals.total - totals.videos),
                                            videos: totals.videos,
                                            albums: meta.albums.count,
                                            folders: meta.folders.count,
                                            updatedAt: updated,
                                            error: nil)
        let items = photos.map {
            LibraryOverviewItem(photo: $0, libraryID: path, libraryName: name)
        }
        let favoriteItems = favorites.map {
            LibraryOverviewItem(photo: $0, libraryID: path, libraryName: name)
        }
        return NativeLoad(summary: summary, items: items, favorites: favoriteItems)
    }

    /// 只读一个打开过的 App 图库的数据库，取体量 / 相簿 / 文件夹数与更新时间。
    /// 不加载整库资产，避免为一次总览把几十 GB 的图库读进内存。
    static func loadAppLibrary(path: String, name: String) -> LibraryOverviewSummary? {
        let url = URL(fileURLWithPath: path)
        guard let dbURL = LibraryPaths.existingMetadataFile(in: url) else { return nil }
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        let totals = (try? db.query("""
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN kind = 'video' THEN 1 ELSE 0 END) AS videos
            FROM assets WHERE deleted_at IS NULL AND is_hidden = 0
            """))?.first
        let total = totals?["total"]?.int ?? 0
        let videos = totals?["videos"]?.int ?? 0
        let albums = (try? db.query("SELECT COUNT(*) AS c FROM albums"))?.first?["c"]?.int ?? 0
        let folders = (try? db.query("SELECT COUNT(*) AS c FROM folders"))?.first?["c"]?.int ?? 0
        let updated = (try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date
        return LibraryOverviewSummary(id: path,
                                      name: name,
                                      path: path,
                                      isNative: false,
                                      isAppContainer: false,
                                      photos: max(0, total - videos),
                                      videos: videos,
                                      albums: albums,
                                      folders: folders,
                                      updatedAt: updated,
                                      error: nil,
                                      isOtherAppLibrary: true)
    }
}
