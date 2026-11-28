// GPS + POI 探测：从 goldset.json 里取带 GPS 的照片，反查 CLPlacemark，
// 统计 areasOfInterest（具体景点）/ thoroughfare（街道）/ name（地名）的命中情况。
// 只读 EXIF 坐标，不复制、不上传照片；反查走系统地理编码。
//
// 编译：
//   swiftc -O -parse-as-library Tools/vision_bench/poi_probe.swift \
//     -o /tmp/poi_probe -framework CoreLocation -framework ImageIO -framework Foundation
//
// 运行：
//   /tmp/poi_probe goldset.json [limit=20] [poi.json]

import Foundation
import ImageIO
import CoreLocation

private struct Sample: Codable {
    let latitude: Double
    let longitude: Double
    let path: String
}

private struct Result: Codable {
    var latitude: Double
    var longitude: Double
    var path: String
    var name: String?
    var areasOfInterest: [String]
    var thoroughfare: String?
    var locality: String?
    var administrativeArea: String?
    var country: String?
    var error: String?
}

@main
enum POIProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: poi_probe <goldset.json> [limit=20] [poi.json]")
            exit(2)
        }
        let goldURL = URL(fileURLWithPath: args[1])
        let limit = args.count > 2 ? (Int(args[2]) ?? 20) : 20
        let outputURL = URL(fileURLWithPath: args.count > 3 ? args[3] : "poi.json")

        guard let data = try? Data(contentsOf: goldURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            print("FAIL 读不到 goldset：\(goldURL.path)")
            exit(1)
        }

        var seen = Set<String>()
        var samples: [Sample] = []
        for item in items {
            guard item["gps"] as? Bool == true,
                  let path = item["path"] as? String,
                  let coordinate = coordinate(path: path) else { continue }
            let key = String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
            guard seen.insert(key).inserted else { continue }
            samples.append(Sample(latitude: coordinate.latitude,
                                  longitude: coordinate.longitude,
                                  path: path))
            if samples.count >= limit { break }
        }
        print("GPS 去重后取 \(samples.count) 个坐标（上限 \(limit)）")

        let geocoder = CLGeocoder()
        var results: [Result] = []
        for (index, sample) in samples.enumerated() {
            let location = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
            var result = Result(latitude: sample.latitude,
                                longitude: sample.longitude,
                                path: sample.path,
                                name: nil,
                                areasOfInterest: [],
                                thoroughfare: nil,
                                locality: nil,
                                administrativeArea: nil,
                                country: nil,
                                error: nil)
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    result = Result(latitude: sample.latitude,
                                    longitude: sample.longitude,
                                    path: sample.path,
                                    name: placemark.name,
                                    areasOfInterest: placemark.areasOfInterest ?? [],
                                    thoroughfare: placemark.thoroughfare,
                                    locality: placemark.locality,
                                    administrativeArea: placemark.administrativeArea,
                                    country: placemark.country,
                                    error: nil)
                } else {
                    result.error = "no-placemark"
                }
            } catch {
                result.error = String(describing: error)
            }
            results.append(result)
            let poi = result.areasOfInterest.joined(separator: "/")
            print("  \(index + 1)/\(samples.count) \(String(format: "%.4f,%.4f", sample.latitude, sample.longitude)) poi=\(poi.isEmpty ? "-" : poi) street=\(result.thoroughfare ?? "-") name=\(result.name ?? "-")")
            // 地理编码有频率限制，串行加 1 秒间隔。
            if index + 1 < samples.count { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }

        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "count": results.count,
            "items": results.map { result -> [String: Any] in
                ["latitude": result.latitude,
                 "longitude": result.longitude,
                 "path": result.path,
                 "name": result.name ?? "",
                 "areasOfInterest": result.areasOfInterest,
                 "thoroughfare": result.thoroughfare ?? "",
                 "locality": result.locality ?? "",
                 "administrativeArea": result.administrativeArea ?? "",
                 "country": result.country ?? "",
                 "error": result.error ?? ""]
            }
        ]
        do {
            let out = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: outputURL, options: .atomic)
            print("wrote \(outputURL.path)")
        } catch {
            print("FAIL 写入失败：\(error)")
            exit(1)
        }
        let withPOI = results.filter { !$0.areasOfInterest.isEmpty }.count
        let withStreet = results.filter { ($0.thoroughfare ?? "").isEmpty == false }.count
        print("POI 命中 \(withPOI)/\(results.count)，街道命中 \(withStreet)/\(results.count)")
    }

    private static func coordinate(path: String) -> (latitude: Double, longitude: Double)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] else {
            return nil
        }
        func value(_ key: CFString, refKey: CFString, positive: String) -> Double? {
            guard let raw = gps[key as String] else { return nil }
            var number: Double?
            if let double = raw as? Double { number = double }
            else if let string = raw as? String { number = Double(string) }
            guard let number else { return nil }
            let ref = (gps[refKey as String] as? String)?.uppercased()
            return ref == positive ? number : -number
        }
        guard let latitude = value(kCGImagePropertyGPSLatitude,
                                   refKey: kCGImagePropertyGPSLatitudeRef,
                                   positive: "N"),
              let longitude = value(kCGImagePropertyGPSLongitude,
                                    refKey: kCGImagePropertyGPSLongitudeRef,
                                    positive: "E") else {
            return nil
        }
        return (latitude, longitude)
    }
}
