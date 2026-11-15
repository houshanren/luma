import Foundation
import CoreLocation

// MARK: - 坐标有效性

enum CoordinateValidator {
    /// 官方图库对没有位置的照片会写入 (-180, -180) 之类的哨兵值，需要过滤。
    static func isValid(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite else { return false }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        if abs(latitude) < 0.0001, abs(longitude) < 0.0001 { return false }
        return true
    }
}

// MARK: - 地点信息

/// 一张照片对应的地点信息，来自官方图库的反向地理编码数据，或本地逆地理编码。
struct PlaceInfo: Codable, Hashable {
    var country: String?
    var province: String?
    var city: String?
    var district: String?
    var poi: String?

    var isEmpty: Bool {
        country == nil && province == nil && city == nil && district == nil && poi == nil
    }

    /// 展示名称：优先「城市，区县」。
    var displayName: String? {
        var parts: [String] = []
        if let city, !city.isEmpty { parts.append(city) }
        if let district, !district.isEmpty, district != city { parts.append(district) }
        if !parts.isEmpty { return parts.joined(separator: "，") }
        if let poi, !poi.isEmpty { return poi }
        if let province, !province.isEmpty { return province }
        if let country, !country.isEmpty { return country }
        return nil
    }

    /// 统计分组：中国大陆 / 其他国家或地区。
    var regionGroup: String {
        guard let country, !country.isEmpty else { return "其他地点" }
        if country.contains("中国"),
           !country.contains("香港"),
           !country.contains("澳门"),
           !country.contains("台湾") {
            return "中国大陆"
        }
        return country
    }
}

// MARK: - 地点聚类

struct PlaceCluster: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let group: String
    let photos: [PhotoItem]
    let latitude: Double
    let longitude: Double

    var count: Int { photos.count }
    var cover: PhotoItem? { photos.first }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum PlaceClusterBuilder {
    static func key(for photo: PhotoItem) -> (id: String, title: String, subtitle: String?, group: String) {
        let country = photo.placeCountry
        let province = photo.placeProvince
        let city = photo.placeCity
        let district = photo.placeDistrict

        if city != nil || district != nil || province != nil {
            var titleParts: [String] = []
            if let city, !city.isEmpty { titleParts.append(city) }
            if let district, !district.isEmpty, district != city { titleParts.append(district) }
            var title = titleParts.joined(separator: "，")
            if title.isEmpty {
                title = province ?? country ?? "未知地点"
            }
            let subtitle: String? = {
                guard let province, !province.isEmpty, province != title else { return nil }
                return province
            }()
            let group = PlaceInfo(country: country,
                                  province: province,
                                  city: city,
                                  district: district,
                                  poi: nil).regionGroup
            let id = [country, province, city, district].map { $0 ?? "" }.joined(separator: "|")
            return (id, title, subtitle, group)
        }

        // 没有地名：用约 1 公里的网格聚合，标题显示坐标。
        let lat = photo.latitude ?? 0
        let lon = photo.longitude ?? 0
        let id = String(format: "geo|%.2f|%.2f", lat, lon)
        let title = String(format: "%.2f°N, %.2f°E", lat, lon)
        return (id, title, "未命名地点", "其他地点")
    }

    static func clusters(from photos: [PhotoItem]) -> [PlaceCluster] {
        struct Bucket {
            var title: String
            var subtitle: String?
            var group: String
            var photos: [PhotoItem]
            var latSum: Double
            var lonSum: Double
            var count: Int
        }

        var buckets: [String: Bucket] = [:]
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude else { continue }
            let key = key(for: photo)
            if var bucket = buckets[key.id] {
                bucket.photos.append(photo)
                bucket.latSum += lat
                bucket.lonSum += lon
                bucket.count += 1
                buckets[key.id] = bucket
            } else {
                buckets[key.id] = Bucket(title: key.title,
                                         subtitle: key.subtitle,
                                         group: key.group,
                                         photos: [photo],
                                         latSum: lat,
                                         lonSum: lon,
                                         count: 1)
            }
        }

        return buckets.map { id, bucket in
            PlaceCluster(id: id,
                         title: bucket.title,
                         subtitle: bucket.subtitle,
                         group: bucket.group,
                         photos: bucket.photos.sorted { $0.capturedAt > $1.capturedAt },
                         latitude: bucket.latSum / Double(bucket.count),
                         longitude: bucket.lonSum / Double(bucket.count))
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

// MARK: - 官方图库反向地理位置解码

/// 解析 `ZREVERSELOCATIONDATA`（NSKeyedArchiver 二进制 plist）。
/// 其中包含 `CNPostalAddress`（国家/省/市/区/街道），无需联网即可得到官方地名。
enum ReverseGeoArchive {
    private static let uidValueFunction: ((CFTypeRef) -> UInt32)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
              let symbol = dlsym(handle, "_CFKeyedArchiverUIDGetValue") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFTypeRef) -> UInt32).self)
    }()

    private static let uidTypeIDFunction: (() -> CFTypeID)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
              let symbol = dlsym(handle, "_CFKeyedArchiverUIDGetTypeID") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> CFTypeID).self)
    }()

    static func decode(_ data: Data) -> PlaceInfo? {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return nil }

        func uidIndex(_ value: Any) -> Int {
            if let function = uidValueFunction, let typeFunction = uidTypeIDFunction,
               CFGetTypeID(value as CFTypeRef) == typeFunction() {
                return Int(function(value as CFTypeRef))
            }
            let description = String(describing: value)
            guard let range = description.range(of: "value = ") else { return -1 }
            let digits = description[range.upperBound...].prefix { $0.isNumber }
            return Int(digits) ?? -1
        }

        func string(_ value: Any?) -> String? {
            guard let value else { return nil }
            let index = uidIndex(value)
            guard index > 0, index < objects.count, let text = objects[index] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func integer(_ value: Any?) -> Int? {
            guard let value else { return nil }
            let index = uidIndex(value)
            guard index > 0, index < objects.count else { return nil }
            if let number = objects[index] as? Int { return number }
            if let number = objects[index] as? NSNumber { return number.intValue }
            return nil
        }

        for object in objects {
            guard let dict = object as? [String: Any] else { continue }
            guard dict["_city"] != nil || dict["_subLocality"] != nil || dict["_country"] != nil else { continue }
            let info = PlaceInfo(country: string(dict["_country"]),
                                 province: string(dict["_state"]),
                                 city: string(dict["_city"]),
                                 district: string(dict["_subLocality"]),
                                 poi: string(dict["_street"]))
            if !info.isEmpty { return info }
        }

        // 兜底：从 sortedPlaceInfos 的层级名称里取城市 / 区县。
        var fallback = PlaceInfo()
        for object in objects {
            guard let dict = object as? [String: Any], dict["name"] != nil else { continue }
            guard let type = integer(dict["placeType"]), let name = string(dict["name"]) else { continue }
            switch type {
            case 1: fallback.country = fallback.country ?? name
            case 2: fallback.province = fallback.province ?? name
            case 4: fallback.city = fallback.city ?? name
            case 6: fallback.district = fallback.district ?? name
            default: break
            }
        }
        return fallback.isEmpty ? nil : fallback
    }
}

// MARK: - 坐标系纠偏

/// WGS-84 / GCJ-02 / BD-09 之间的转换，用于高德、百度底图对齐。
enum CoordinateShift {
    private static let axis = 6378245.0
    private static let eccentricity = 0.00669342162296594323
    private static let xPi = Double.pi * 3000.0 / 180.0

    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    static func wgs84ToGcj02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        var deltaLat = transformLatitude(longitude - 105.0, latitude - 35.0)
        var deltaLon = transformLongitude(longitude - 105.0, latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - eccentricity * magic * magic
        let sqrtMagic = sqrt(magic)
        deltaLat = (deltaLat * 180.0) / ((axis * (1 - eccentricity)) / (magic * sqrtMagic) * .pi)
        deltaLon = (deltaLon * 180.0) / (axis / sqrtMagic * cos(radLat) * .pi)
        return (latitude + deltaLat, longitude + deltaLon)
    }

    static func gcj02ToBd09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let z = sqrt(longitude * longitude + latitude * latitude) + 0.00002 * sin(latitude * xPi)
        let theta = atan2(latitude, longitude) + 0.000003 * cos(longitude * xPi)
        return (z * sin(theta) + 0.006, z * cos(theta) + 0.0065)
    }

    static func wgs84ToBd09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let gcj = wgs84ToGcj02(latitude: latitude, longitude: longitude)
        return gcj02ToBd09(latitude: gcj.latitude, longitude: gcj.longitude)
    }

    // MARK: 百度墨卡托

    private static let mcBands: [Double] = [12890594.86, 8362377.87, 5591021, 3481989.83, 1678043.12, 0]
    private static let ll2mc: [[Double]] = [
        [-0.0015702102444, 111320.7020616939, 1704480524535203, -10338987376042340,
         26112667856603880, -35149669176653700, 26595700718403920, -10725012454188240,
         1800819912950474, 82.5],
        [0.0008277824516172526, 111320.7020463578, 647795574.6671607, -4082003173.641316,
         10774905663.51142, -15171875531.51559, 12053065338.62167, -5124939663.577472,
         913311935.9512032, 67.5],
        [0.00337398766765, 111320.7020202162, 4481351.045890365, -23393751.19931662,
         79682215.47186455, -115964993.2797253, 97236711.15602145, -43661946.33752821,
         8477230.501135234, 52.5],
        [0.00220636496208, 111320.7020209128, 51751.86112841131, 3796837.749470245,
         992013.7397791013, -1221952.21711287, 1340652.697009075, -620943.6990984312,
         144416.9293806241, 37.5],
        [-0.0003441963504368392, 111320.7020576856, 278.2353980772752, 2485758.690035394,
         6070.750963243378, 54821.18345352118, 9540.606633304236, -2710.55326746645,
         1405.483844121726, 22.5],
        [-0.0003218135878613132, 111320.7020701615, 0.00369383431289, 823725.6402795718,
         0.46104986909093, 2351.343141331292, 1.58060784298199, 8.77738589078284,
         0.37238884252424, 7.45]
    ]

    /// BD-09 经纬度 → 百度墨卡托（米）。
    static func bd09ToMercator(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let absLon = abs(longitude)
        let absLat = abs(latitude)
        var coefficient: [Double]?
        for (index, band) in mcBands.enumerated() where absLat >= band {
            coefficient = ll2mc[index]
            break
        }
        guard let c = coefficient else { return (0, 0) }
        let x = c[0] + c[1] * absLon
        let unit = absLat / c[9]
        var y = c[2]
        var power = unit
        for index in 3...8 {
            y += c[index] * power
            power *= unit
        }
        return (longitude < 0 ? -x : x, latitude < 0 ? -y : y)
    }

    /// 百度瓦片编号（256px）。
    static func baiduTile(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let bd = wgs84ToBd09(latitude: latitude, longitude: longitude)
        let mc = bd09ToMercator(latitude: bd.latitude, longitude: bd.longitude)
        let resolution = 0.597164283559817 * pow(2.0, Double(18 - zoom))
        let world = 20037726.37
        let x = Int(floor((mc.x + world) / (256.0 * resolution)))
        let y = Int(floor((world - mc.y) / (256.0 * resolution)))
        return (x, y)
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}
