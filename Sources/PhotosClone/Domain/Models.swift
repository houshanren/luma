import Foundation
import CoreGraphics

enum MediaKind: String, Codable {
    case photo
    case video
    case screenshot
    case panorama
    case selfie
}

enum PhotoSource: String, Codable {
    case local
    case system
    case cloud
}

struct PhotoItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var editedFilename: String?
    var originalName: String
    /// 用户自定义标题（与官方「照片」的标题一致，可与文件名不同）。
    var title: String?
    var capturedAt: Date
    var addedAt: Date = Date()
    /// 同一批导入共用的批次 ID，用于「导入项目」按批次分组。
    var importBatchID: UUID?
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var kind: MediaKind = .photo
    var isFavorite: Bool = false
    var isHidden: Bool = false
    var deletedAt: Date?
    var editVersion: Int = 0
    var duration: Double?
    /// 非破坏性旋转：0/90/180/270，顺时针。为兼容旧数据使用可选值。
    var rotation: Int?

    var make: String?
    var model: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var latitude: Double?
    var longitude: Double?
    var placeCountry: String?
    var placeProvince: String?
    var placeCity: String?
    var placeDistrict: String?
    var placePOI: String?
    var keywords: [String]?

    var source: PhotoSource?
    var systemOriginalPath: String?
    var systemThumbnailPath: String?
    /// 编辑配方（EditState 的 JSON），用于再次进入编辑器与复制/粘贴编辑点。
    var editRecipe: String?
    var isPortraitCapture: Bool = false
    var isDuplicateItem: Bool = false
    var isDeviceImport: Bool = false
    /// 官方图库中的实况照片 / 连拍项目（仅官方库可判定）。
    var isLivePhoto: Bool = false
    var isBurstItem: Bool = false
    /// 本地实况照片的配对视频文件名（位于 originals/<分片>/）。
    var livePhotoFilename: String?
    /// 系统图库实况照片的配对视频绝对路径。
    var livePhotoVideoPath: String?
    /// 慢动作视频（系统图库按 ZKINDSUBTYPE = 101 判定）。
    var isSlowMotion: Bool = false
    /// 录屏视频（系统图库按 ZISDETECTEDSCREENSHOT 判定）。
    var isScreenRecording: Bool = false
    /// 动图（系统图库按 ZPLAYBACKSTYLE = 2 判定）。
    var isAnimated: Bool = false
    /// 最近查看 / 最近编辑时间（仅系统图库可读，本地库为 nil）。
    var viewedAt: Date?
    var editedAt: Date?

    var cloudMountID: UUID?
    var cloudPath: String?
    var cloudRemoteID: String?
    var cloudThumbnailURL: String?

    var displayFilename: String { editedFilename ?? filename }
    /// 展示用标题：优先用户标题，否则用原始文件名。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return originalName
    }
    var isVideo: Bool { kind == .video }
    var hasEdits: Bool { editedFilename != nil }
    /// 按扩展名判定 RAW（导入与系统图库都适用）。
    var isRAWFile: Bool {
        let ext = (originalName as NSString).pathExtension.lowercased()
        return Self.rawExtensions.contains(ext)
    }
    /// 按扩展名判定动图（系统图库另有 isAnimated）。
    var isAnimatedFile: Bool {
        (originalName as NSString).pathExtension.lowercased() == "gif"
    }

    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
        "rw2", "pef", "srw", "raw", "3fr", "erf", "mef", "mos", "iiq", "rwl"
    ]

    var isSystem: Bool { source == .system }
    var isCloud: Bool { source == .cloud }
    var isReadOnly: Bool { source == .system || source == .cloud }
    var cacheKey: String { "\(source?.rawValue ?? "local")-\(id.uuidString)-\(editVersion)" }
    var rotationAngle: Int {
        let value = ((rotation ?? 0) % 360 + 360) % 360
        return [0, 90, 180, 270].contains(value) ? value : 0
    }
    var isRotated: Bool { rotationAngle != 0 }
    var displayPixelWidth: Int {
        rotationAngle == 90 || rotationAngle == 270 ? pixelHeight : pixelWidth
    }
    var displayPixelHeight: Int {
        rotationAngle == 90 || rotationAngle == 270 ? pixelWidth : pixelHeight
    }
    var aspectRatio: CGFloat {
        guard displayPixelHeight > 0 else { return 1 }
        return CGFloat(displayPixelWidth) / CGFloat(displayPixelHeight)
    }
    var isDeleted: Bool { deletedAt != nil }
    var hasLocation: Bool { CoordinateValidator.isValid(latitude: latitude, longitude: longitude) }
    var tags: [String] { keywords ?? [] }
}

struct KeywordOption: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct Album: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var photoIDs: [UUID] = []
    var folderID: UUID?
    /// 用户指定的封面（可为照片或视频）；为空时取相簿内第一张。
    var coverPhotoID: UUID?
}

struct AlbumFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var parentID: UUID?
    var createdAt: Date = Date()
}

struct FolderOption: Identifiable {
    let id: UUID
    let path: String
}

enum SidebarItem: Hashable {
    case library
    case collections
    case favorites
    case recentlySaved
    case duplicates
    case map
    case places
    case people
    case videos
    case screenshots
    case hidden
    case allAlbums
    case album(UUID)
    case smartAlbum(UUID)
    case folder(UUID)
    case selfies
    case panoramas
    case livePhotos
    case animated
    case raws
    case recentlyEdited
    case imports
    case ocrTexts
    case scene(String)
    /// 图库体检：模糊照片、相似连拍备选、过大视频与「值得重看」范围。
    case health
    case blurry
    case similarDuplicates
    case largeVideos
    case revisit
    case trash
    case systemLibrary
    case systemAlbum(Int64)
    case systemFolder(Int64)
    case systemFavorites
    case systemVideos
    case systemScreenshots
    case systemHidden
    case systemTrash
    case systemSharedAlbums
    case systemPortraits
    case systemSelfies
    case systemLivePhotos
    case systemPanoramas
    case systemSlowMotion
    case systemScreenRecordings
    case systemAnimated
    case systemRAW
    case systemEdited
    case systemRecentlyViewed
    case systemDuplicates
    case systemHandwriting
    case systemIllustrations
    case systemRecentlySaved
    case systemImports
    case systemMap
    case systemPlaces
    case systemPeople
    case cloudMount(UUID)

    /// 是否属于只读的系统「照片」图库范围。
    var isSystemScope: Bool {
        switch self {
        case .systemLibrary, .systemAlbum, .systemFolder, .systemFavorites, .systemVideos,
             .systemScreenshots, .systemHidden, .systemTrash, .systemSharedAlbums,
             .systemPortraits, .systemSelfies, .systemLivePhotos, .systemPanoramas,
             .systemSlowMotion, .systemScreenRecordings, .systemAnimated, .systemRAW,
             .systemEdited, .systemRecentlyViewed, .systemDuplicates, .systemHandwriting,
             .systemIllustrations, .systemRecentlySaved, .systemImports, .systemMap,
             .systemPlaces, .systemPeople:
            return true
        default:
            return false
        }
    }
}

struct SystemAlbumInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let parentFolder: Int64?
    let assetIDs: [UUID]
    /// 图库内原始顺序（Photos.sqlite 的 Z_PK），用于与官方「照片」保持一致的相簿排序。
    var sortIndex: Int64 = 0
}

struct SystemFolderInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let parent: Int64?
    /// 图库内原始顺序（Photos.sqlite 的 Z_PK）；与相簿共用同一序列，可混排。
    var sortIndex: Int64 = 0
}

/// 系统图库侧边栏的一个条目：文件夹与相簿按原始顺序混排。
enum SystemSidebarEntry: Identifiable {
    case folder(SystemFolderInfo)
    case album(SystemAlbumInfo)

    var id: String {
        switch self {
        case .folder(let folder): return "folder-\(folder.id)"
        case .album(let album): return "album-\(album.id)"
        }
    }

    var sortIndex: Int64 {
        switch self {
        case .folder(let folder): return folder.sortIndex
        case .album(let album): return album.sortIndex
        }
    }
}

/// 已连接的系统「照片」图库（可同时登记多个，侧边栏逐个展示）。
struct SystemLibraryRef: Identifiable, Codable, Hashable {
    var path: String
    var name: String

    var id: String { path }
}

/// 被固定到侧边栏「固定」分区的项目：系统智能项、相簿或文件夹。
enum PinnedSidebarItem: Codable, Hashable, Identifiable {
    case system(String)
    case album(UUID)
    case folder(UUID)

    var id: String {
        switch self {
        case .system(let key): return "system-\(key)"
        case .album(let id): return "album-\(id.uuidString)"
        case .folder(let id): return "folder-\(id.uuidString)"
        }
    }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case edited
    case photos
    case videos
    case screenshots
    case mine
    case notInAlbum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "所有项目"
        case .favorites: return "个人收藏"
        case .edited: return "已编辑"
        case .photos: return "照片"
        case .videos: return "视频"
        case .screenshots: return "截屏"
        case .mine: return "由我拍摄"
        case .notInAlbum: return "不在相簿中"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "heart"
        case .edited: return "slider.horizontal.3"
        case .photos: return "photo"
        case .videos: return "video"
        case .screenshots: return "camera.viewfinder"
        case .mine: return "camera"
        case .notInAlbum: return "rectangle.stack.badge.minus"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case capturedAt
    case addedAt
    case title
    case filename
    case fileSize
    case kind
    case camera
    case place
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capturedAt: return "拍摄日期"
        case .addedAt: return "添加日期"
        case .title: return "标题"
        case .filename: return "文件名"
        case .fileSize: return "文件大小"
        case .kind: return "文件类型"
        case .camera: return "相机"
        case .place: return "地点"
        case .duration: return "时长"
        }
    }

    var icon: String {
        switch self {
        case .capturedAt: return "calendar"
        case .addedAt: return "tray.and.arrow.down"
        case .title: return "textformat"
        case .filename: return "doc.text"
        case .fileSize: return "internaldrive"
        case .kind: return "square.stack.3d.up"
        case .camera: return "camera"
        case .place: return "mappin.and.ellipse"
        case .duration: return "timer"
        }
    }

    /// 名称类默认升序，日期/大小类默认降序。
    var prefersAscending: Bool {
        switch self {
        case .title, .filename, .kind, .camera, .place: return true
        default: return false
        }
    }

    var directionTitle: String {
        switch self {
        case .capturedAt, .addedAt: return "升序为最旧优先，降序为最新优先"
        case .title, .filename, .kind, .camera, .place: return "升序为 A→Z，降序为 Z→A"
        case .fileSize, .duration: return "升序为从小到大，降序为从大到小"
        }
    }
}

enum ThumbnailAspect: String, CaseIterable, Identifiable {
    case square
    case actual
    case masonry
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "正方形"
        case .actual: return "完整宽高比"
        case .masonry: return "瀑布流"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .square: return "square.grid.2x2"
        case .actual: return "aspectratio"
        case .masonry: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        }
    }
}

enum GridGrouping: String, CaseIterable, Identifiable {
    case years
    case months
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .years: return "年"
        case .months: return "月"
        case .all: return "所有照片"
        }
    }
}

struct PhotoSection: Identifiable {
    let id: String
    let title: String?
    let photos: [PhotoItem]
}

enum CropAspect: String, Codable, CaseIterable, Identifiable {
    case original
    case square
    case fourThree
    case threeFour
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始"
        case .square: return "正方形"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

enum FilterPreset: String, Codable, CaseIterable, Identifiable {
    case none
    case vivid
    case warm
    case cool
    case mono
    case instant
    case noir
    case fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "原片"
        case .vivid: return "鲜明"
        case .warm: return "暖色"
        case .cool: return "冷色"
        case .mono: return "黑白"
        case .instant: return "复古"
        case .noir: return "银盐"
        case .fade: return "褪色"
        }
    }

    var ciName: String? {
        switch self {
        case .none: return nil
        case .vivid: return "CIPhotoEffectChrome"
        case .warm: return "CIPhotoEffectTransfer"
        case .cool: return "CIPhotoEffectProcess"
        case .mono: return "CIPhotoEffectMono"
        case .instant: return "CIPhotoEffectInstant"
        case .noir: return "CIPhotoEffectNoir"
        case .fade: return "CIPhotoEffectFade"
        }
    }
}

enum DateText {
    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年"
        return f
    }()

    static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
}

func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
