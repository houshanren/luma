import Foundation

/// 「个人收藏」的浏览方式：全部网格，或按年份 / 类型 / 地点 / 相机 / 人物汇总。
/// 每个维度单独占一屏，先看分类卡片，再点卡片下钻。
package enum FavoritesViewMode: String, CaseIterable, Identifiable {
    case all
    case years
    case kinds
    case places
    case cameras
    case people

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .all: return "全部"
        case .years: return "年"
        case .kinds: return "类型"
        case .places: return "地点"
        case .cameras: return "相机"
        case .people: return "人物"
        }
    }

    package var hint: String {
        switch self {
        case .all: return "平铺显示所有收藏"
        case .years: return "按拍摄年份汇总收藏"
        case .kinds: return "按照片 / 视频 / 实况等类型汇总"
        case .places: return "按城市汇总收藏"
        case .cameras: return "按相机或手机品牌汇总"
        case .people: return "按已命名人物汇总"
        }
    }

    package var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .years: return "calendar"
        case .kinds: return "square.stack.3d.up"
        case .places: return "mappin.and.ellipse"
        case .cameras: return "camera"
        case .people: return "person.2"
        }
    }
}

/// 收藏按类型分组时的互斥分桶：实况照片、截屏等优先于普通照片。
package enum FavoriteKindBucket: String, CaseIterable, Identifiable {
    case photos
    case videos
    case livePhotos
    case screenshots
    case selfies
    case panoramas

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .photos: return "照片"
        case .videos: return "视频"
        case .livePhotos: return "实况照片"
        case .screenshots: return "截屏"
        case .selfies: return "自拍"
        case .panoramas: return "全景照片"
        }
    }

    package var icon: String {
        switch self {
        case .photos: return "photo"
        case .videos: return "video"
        case .livePhotos: return "livephoto"
        case .screenshots: return "camera.viewfinder"
        case .selfies: return "person.crop.square"
        case .panoramas: return "pano"
        }
    }

    package static func bucket(for photo: PhotoItem) -> FavoriteKindBucket {
        if photo.isVideo { return .videos }
        if photo.isLivePhoto { return .livePhotos }
        switch photo.kind {
        case .screenshot: return .screenshots
        case .selfie: return .selfies
        case .panorama: return .panoramas
        case .photo, .video: return .photos
        }
    }
}

/// 地点 / 相机汇总共用的分组键：与照片元数据里的字段保持一致。
package enum FavoritesDigestKeys {
    package static func year(_ photo: PhotoItem) -> String {
        String(Calendar.current.component(.year, from: photo.capturedAt))
    }

    /// 收藏按城市聚合；没有城市时逐级回退到省份 / 国家。
    package static func place(_ photo: PhotoItem) -> String? {
        firstNonEmpty(photo.placeCity, photo.placeProvince, photo.placeCountry)
    }

    package static func placeSubtitle(for photo: PhotoItem, title: String) -> String? {
        let province = firstNonEmpty(photo.placeProvince)
        if let province, province != title { return province }
        let country = firstNonEmpty(photo.placeCountry)
        return country != title ? country : nil
    }

    /// 收藏按品牌聚合（相机 / 手机），便于用品牌插画展示。
    package static func camera(_ photo: PhotoItem) -> String? {
        let text = [photo.make, photo.model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let brand = CameraBrand.detect(text)
        return brand == .other ? text : brand.title
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// 收藏汇总里的相机 / 手机品牌：只做识别与命名，颜色与插画在视图层。
package enum CameraBrand: String, CaseIterable {
    case apple
    case canon
    case nikon
    case sony
    case fujifilm
    case leica
    case hasselblad
    case dji
    case gopro
    case xiaomi
    case huawei
    case samsung
    case google
    case oppo
    case vivo
    case oneplus
    case panasonic
    case olympus
    case pentax
    case insta360
    case other

    package var title: String {
        switch self {
        case .apple: return "Apple"
        case .canon: return "Canon"
        case .nikon: return "Nikon"
        case .sony: return "Sony"
        case .fujifilm: return "Fujifilm"
        case .leica: return "Leica"
        case .hasselblad: return "Hasselblad"
        case .dji: return "DJI"
        case .gopro: return "GoPro"
        case .xiaomi: return "Xiaomi"
        case .huawei: return "Huawei"
        case .samsung: return "Samsung"
        case .google: return "Pixel"
        case .oppo: return "OPPO"
        case .vivo: return "vivo"
        case .oneplus: return "OnePlus"
        case .panasonic: return "Lumix"
        case .olympus: return "OM System"
        case .pentax: return "Pentax"
        case .insta360: return "Insta360"
        case .other: return "其他"
        }
    }

    /// 手机品牌使用手机插画，其余使用相机插画。
    package var isPhone: Bool {
        switch self {
        case .apple, .xiaomi, .huawei, .samsung, .google, .oppo, .vivo, .oneplus:
            return true
        default:
            return false
        }
    }

    package static func detect(_ text: String) -> CameraBrand {
        let value = text.lowercased()
        if value.contains("iphone") || value.contains("ipad") || value.contains("apple") { return .apple }
        if value.contains("canon") { return .canon }
        if value.contains("nikon") { return .nikon }
        if value.contains("sony") || value.contains("ilce") || value.contains("dsc-") { return .sony }
        if value.contains("fuji") || value.contains("x100") || value.contains("x-t") || value.contains("gfx") { return .fujifilm }
        if value.contains("leica") { return .leica }
        if value.contains("hasselblad") { return .hasselblad }
        if value.contains("dji") || value.contains("mavic") || value.contains("osmo") { return .dji }
        if value.contains("gopro") || value.contains("hero") { return .gopro }
        if value.contains("xiaomi") || value.contains("redmi") { return .xiaomi }
        if value.contains("huawei") || value.contains("honor") { return .huawei }
        if value.contains("samsung") || value.contains("galaxy") { return .samsung }
        if value.contains("google") || value.contains("pixel") { return .google }
        if value.contains("oneplus") { return .oneplus }
        if value.contains("oppo") { return .oppo }
        if value.contains("vivo") { return .vivo }
        if value.contains("panasonic") || value.contains("lumix") { return .panasonic }
        if value.contains("olympus") || value.contains("om system") { return .olympus }
        if value.contains("pentax") || value.contains("ricoh") { return .pentax }
        if value.contains("insta360") { return .insta360 }
        return .other
    }
}

/// 收藏汇总里的一个可下钻分类。
package struct FavoritesBucketSelection: Identifiable, Hashable {
    package enum Dimension: String, Hashable {
        case year
        case kind
        case place
        case camera
        case person
    }

    package let dimension: Dimension
    package let key: String
    package let title: String
    package let subtitle: String?
    /// 人物维度：该人物名下的照片 ID，用于从收藏源里过滤。
    package var assetIDs: Set<UUID> = []

    package var id: String { "\(dimension.rawValue)|\(key)" }

    package func matches(_ photo: PhotoItem) -> Bool {
        switch dimension {
        case .year:
            return FavoritesDigestKeys.year(photo) == key
        case .kind:
            return FavoriteKindBucket.bucket(for: photo).rawValue == key
        case .place:
            return FavoritesDigestKeys.place(photo) == key
        case .camera:
            return FavoritesDigestKeys.camera(photo) == key
        case .person:
            return assetIDs.contains(photo.id)
        }
    }
    package init(
        dimension: Dimension,
        key: String,
        title: String,
        subtitle: String? = nil,
        assetIDs: Set<UUID> = []
    ) {
        self.dimension = dimension
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.assetIDs = assetIDs
    }
}

/// 汇总卡片：封面最多保留 4 张，数量是完整统计值。
package struct FavoritesDigestBucket: Identifiable {
    package let selection: FavoritesBucketSelection
    package let count: Int
    package let photos: [PhotoItem]

    package var id: String { selection.id }
    package init(
        selection: FavoritesBucketSelection,
        count: Int,
        photos: [PhotoItem]
    ) {
        self.selection = selection
        self.count = count
        self.photos = photos
    }
}

/// 人物汇总的数据来源：本地聚类或官方人物，只展示已命名的人物。
package struct FavoritesPersonSource {
    package let id: String
    package let name: String
    package let isPet: Bool
    package let isUnnamed: Bool
    package let assetIDs: [UUID]
    package init(
        id: String,
        name: String,
        isPet: Bool,
        isUnnamed: Bool,
        assetIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.isPet = isPet
        self.isUnnamed = isUnnamed
        self.assetIDs = assetIDs
    }
}

/// 「个人收藏」汇总：总量、时间跨度与五个分类维度。
package struct FavoritesDigest {
    package var total = 0
    package var photoCount = 0
    package var videoCount = 0
    package var totalBytes: Int64 = 0
    package var earliest: Date?
    package var latest: Date?
    package var years: [FavoritesDigestBucket] = []
    package var kinds: [FavoritesDigestBucket] = []
    package var places: [FavoritesDigestBucket] = []
    package var cameras: [FavoritesDigestBucket] = []
    package var people: [FavoritesDigestBucket] = []
    /// 系统图库收藏过多、只统计了最近一批时为 true。
    package var isLimited = false

    package var hasContent: Bool { total > 0 }

    /// 汇总页头图：最新一张收藏。
    package var heroPhoto: PhotoItem? {
        years.first?.photos.first
    }
    package init(
        total: Int = 0,
        photoCount: Int = 0,
        videoCount: Int = 0,
        totalBytes: Int64 = 0,
        earliest: Date? = nil,
        latest: Date? = nil,
        years: [FavoritesDigestBucket] = [],
        kinds: [FavoritesDigestBucket] = [],
        places: [FavoritesDigestBucket] = [],
        cameras: [FavoritesDigestBucket] = [],
        people: [FavoritesDigestBucket] = [],
        isLimited: Bool = false
    ) {
        self.total = total
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.totalBytes = totalBytes
        self.earliest = earliest
        self.latest = latest
        self.years = years
        self.kinds = kinds
        self.places = places
        self.cameras = cameras
        self.people = people
        self.isLimited = isLimited
    }
}

package enum FavoritesDigestBuilder {
    package static func make(photos: [PhotoItem],
                     people: [FavoritesPersonSource],
                     isLimited: Bool,
                     maxPeople: Int = 20,
                     maxPlaces: Int = 12,
                     maxCameras: Int = 12) -> FavoritesDigest {
        var digest = FavoritesDigest()
        digest.total = photos.count
        digest.photoCount = photos.lazy.filter { !$0.isVideo }.count
        digest.videoCount = digest.total - digest.photoCount
        digest.totalBytes = photos.reduce(Int64(0)) { $0 + $1.fileSize }
        digest.earliest = photos.map(\.capturedAt).min()
        digest.latest = photos.map(\.capturedAt).max()
        digest.isLimited = isLimited
        guard !photos.isEmpty else { return digest }

        // 统一按拍摄时间倒序，封面取每组最新几张。
        let sorted = photos.sorted { $0.capturedAt > $1.capturedAt }

        let byYear = Dictionary(grouping: sorted, by: FavoritesDigestKeys.year)
        digest.years = byYear.keys.sorted(by: >).compactMap { key in
            guard let list = byYear[key] else { return nil }
            return bucket(.init(dimension: .year, key: key, title: "\(key) 年", subtitle: nil),
                          photos: list)
        }

        let byKind = Dictionary(grouping: sorted, by: FavoriteKindBucket.bucket(for:))
        digest.kinds = FavoriteKindBucket.allCases.compactMap { kind in
            guard let list = byKind[kind], !list.isEmpty else { return nil }
            return bucket(.init(dimension: .kind, key: kind.rawValue, title: kind.title, subtitle: nil),
                          photos: list)
        }

        digest.places = grouped(sorted,
                                key: FavoritesDigestKeys.place,
                                limit: maxPlaces) { photo, title in
            .init(dimension: .place,
                  key: title,
                  title: title,
                  subtitle: FavoritesDigestKeys.placeSubtitle(for: photo, title: title))
        }

        digest.cameras = cameraBuckets(from: sorted, limit: maxCameras)

        digest.people = peopleBuckets(from: sorted, people: people, limit: maxPeople)
        return digest
    }

    private static func bucket(_ selection: FavoritesBucketSelection,
                               photos: [PhotoItem]) -> FavoritesDigestBucket {
        FavoritesDigestBucket(selection: selection,
                              count: photos.count,
                              photos: Array(photos.prefix(4)))
    }

    private static func grouped(_ photos: [PhotoItem],
                                key: (PhotoItem) -> String?,
                                limit: Int,
                                selection: (PhotoItem, String) -> FavoritesBucketSelection)
        -> [FavoritesDigestBucket] {
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        for photo in photos {
            guard let value = key(photo) else { continue }
            if buckets[value] == nil { order.append(value) }
            buckets[value, default: []].append(photo)
        }
        return order
            .compactMap { value -> FavoritesDigestBucket? in
                guard let list = buckets[value], let first = list.first else { return nil }
                return bucket(selection(first, value), photos: list)
            }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    /// 相机 / 手机按品牌聚合，卡片副标题列出常见机型。
    private static func cameraBuckets(from photos: [PhotoItem], limit: Int) -> [FavoritesDigestBucket] {
        struct Group {
            package let brand: CameraBrand
            package var photos: [PhotoItem] = []
            package var models: Set<String> = []
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for photo in photos {
            let text = [photo.make, photo.model]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            let brand = CameraBrand.detect(text)
            let key = brand == .other ? text : brand.title
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(brand: brand)
            }
            groups[key]?.photos.append(photo)
            if let model = photo.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                groups[key]?.models.insert(model)
            }
        }
        return order
            .compactMap { key -> FavoritesDigestBucket? in
                guard let group = groups[key], !group.photos.isEmpty else { return nil }
                let models = group.models.sorted()
                let subtitle = models.prefix(2).joined(separator: " · ")
                let title = group.brand == .other ? key : group.brand.title
                let selection = FavoritesBucketSelection(dimension: .camera,
                                                         key: key,
                                                         title: title,
                                                         subtitle: subtitle.isEmpty ? nil : subtitle)
                return FavoritesDigestBucket(selection: selection,
                                             count: group.photos.count,
                                             photos: Array(group.photos.prefix(4)))
            }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    /// 只汇总已命名的人物：未命名聚类数量多且没有辨识度。
    private static func peopleBuckets(from photos: [PhotoItem],
                                      people: [FavoritesPersonSource],
                                      limit: Int) -> [FavoritesDigestBucket] {
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return people
            .compactMap { person -> FavoritesDigestBucket? in
                guard !person.isUnnamed else { return nil }
                let matched = person.assetIDs.filter { byID[$0] != nil }
                guard !matched.isEmpty else { return nil }
                let covers = matched.compactMap { byID[$0] }
                    .sorted { $0.capturedAt > $1.capturedAt }
                let selection = FavoritesBucketSelection(dimension: .person,
                                                         key: person.id,
                                                         title: person.name,
                                                         subtitle: person.isPet ? "宠物" : nil,
                                                         assetIDs: Set(matched))
                return FavoritesDigestBucket(selection: selection,
                                             count: matched.count,
                                             photos: Array(covers.prefix(4)))
            }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }
}
