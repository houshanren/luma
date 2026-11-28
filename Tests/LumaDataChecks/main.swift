import Foundation
import LumaDomain
import LumaPersistence
import TestSupport

/// 数据层检查：领域模型（格式判定、地点聚类、路径分片）与持久化（SQLite、图库元数据）的边界行为。

func makePhoto(_ name: String,
               latitude: Double? = nil,
               longitude: Double? = nil,
               city: String? = nil) -> PhotoItem {
    PhotoItem(filename: "\(name).jpg",
              originalName: "\(name).jpg",
              capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
              pixelWidth: 100,
              pixelHeight: 100,
              fileSize: 1024,
              latitude: latitude,
              longitude: longitude,
              placeCity: city)
}

func runFormatChecks() {
    expect(VideoFormats.isVideo(URL(fileURLWithPath: "/tmp/a.mkv")), "mkv 按扩展名识别为视频")
    expect(VideoFormats.isVideo(URL(fileURLWithPath: "/tmp/a.MOV")), "扩展名大小写不敏感")
    expect(!VideoFormats.isVideo(URL(fileURLWithPath: "/tmp/a.txt")), "txt 不是视频")
    expect(VideoFormats.isVideoExtension("m2ts"), "m2ts 在白名单里")
    expect(!VideoFormats.isVideoExtension("exe"), "exe 不在视频白名单里")

    expect(MediaTypeSupport.isImageOrVideo(URL(fileURLWithPath: "/tmp/a.png")), "png 是图片")
    expect(MediaTypeSupport.isImageOrVideo(URL(fileURLWithPath: "/tmp/a.dng")), "dng 按 RAW 白名单识别")
    expect(MediaTypeSupport.isImageOrVideo(URL(fileURLWithPath: "/tmp/a.mkv")), "mkv 是视频")
    expect(!MediaTypeSupport.isImageOrVideo(URL(fileURLWithPath: "/tmp/a.txt")), "txt 不是媒体")
}

func runCoordinateChecks() {
    expect(CoordinateValidator.isValid(latitude: 31.23, longitude: 121.47), "常规经纬度有效")
    expect(!CoordinateValidator.isValid(latitude: nil, longitude: 121.47), "缺纬度无效")
    expect(!CoordinateValidator.isValid(latitude: 0, longitude: 0), "零坐标视为无效")
    expect(!CoordinateValidator.isValid(latitude: -180, longitude: -180), "官方图库哨兵坐标无效")
    expect(!CoordinateValidator.isValid(latitude: 91, longitude: 10), "纬度超界无效")
    expect(!CoordinateValidator.isValid(latitude: .nan, longitude: 10), "NaN 坐标无效")
}

func runPlaceClusterChecks() {
    let photos = [
        makePhoto("a", latitude: 31.20, longitude: 121.40, city: "上海"),
        makePhoto("b", latitude: 31.21, longitude: 121.41, city: "上海"),
        makePhoto("c", latitude: 39.90, longitude: 116.40, city: "北京"),
        makePhoto("d") // 无坐标
    ]
    let clusters = PlaceClusterBuilder.clusters(from: photos, granularity: .city)
    expectEqual(clusters.count, 2, "按城市聚成两组")
    let shanghai = clusters.first { $0.title == "上海" }
    expectEqual(shanghai?.count ?? -1, 2, "上海组包含两张照片")
    let beijing = clusters.first { $0.title == "北京" }
    expectEqual(beijing?.count ?? -1, 1, "北京组包含一张照片")
    expectEqual(clusters.reduce(0) { $0 + $1.count }, 3, "无坐标照片不进入聚类")
}

func runPathChecks() {
    let id = UUID()
    let shard = LibraryPaths.shard(for: id)
    expectEqual(shard, String(id.uuidString.prefix(1)), "分片目录取 UUID 首字符")
    expectEqual(LibraryPaths.shard(forFilename: "abc.jpg"), "a", "文件名分片取首字符")
}

func runSQLiteChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("luma-data-checks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    do {
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("t.sqlite").path,
                                    readonly: false)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);")
        try db.executeMany("INSERT INTO t (name) VALUES (?);", rows: [["alpha"], ["beta"]])

        let countRows = try db.query("SELECT COUNT(*) AS c FROM t;")
        expectEqual(countRows.first?["c"]?.int ?? -1, 2, "插入两行后计数为二")

        let one = try db.query("SELECT name FROM t WHERE id = ?;", [1])
        expectEqual(one.first?["name"]?.string ?? "", "alpha", "按绑定参数取回文本")

        let missing = try db.query("SELECT name FROM t WHERE id = ?;", [99])
        expect(missing.isEmpty, "不存在的行返回空结果")
    } catch {
        expect(false, "SQLite 基本读写失败：\(error)")
    }
}

func runMetadataChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("luma-metadata-checks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    do {
        let store = try MetadataStore(url: dir.appendingPathComponent("Luma.sqlite"))
        let photo = makePhoto("shot")
        store.appendPhotos([photo])

        var count = 0
        for _ in 0..<40 {
            count = store.assetCount()
            if count == 1 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        expectEqual(count, 1, "追加照片后资产计数为一")

        let loaded = store.loadAssets(limit: 10, offset: 0)
        expectEqual(loaded.first?.id, photo.id, "按页读回同一张照片")
        expectEqual(loaded.first?.originalName ?? "", "shot.jpg", "文件名保持不变")

        store.setSetting("checks.key", "value")
        expectEqual(store.setting("checks.key") ?? "", "value", "设置键值可写可读")
        store.setSetting("checks.key", nil)
        expect(store.setting("checks.key") == nil, "设置键值可删除")
    } catch {
        expect(false, "图库元数据读写失败：\(error)")
    }
}

func runTrajectoryChecks() {
    let calendar = Calendar.current
    var components = DateComponents()
    components.year = 2024
    components.month = 7
    components.day = 1
    components.hour = 10
    let day1 = calendar.date(from: components)!
    let day1Late = day1.addingTimeInterval(2 * 3600)
    components.day = 2
    let day2 = calendar.date(from: components)!

    func photo(_ name: String, at date: Date, poi: String?) -> PhotoItem {
        PhotoItem(filename: "\(name).jpg",
                  originalName: "\(name).jpg",
                  capturedAt: date,
                  pixelWidth: 100,
                  pixelHeight: 100,
                  fileSize: 1024,
                  placePOI: poi)
    }

    let a = photo("a", at: day1, poi: "海边")
    let b = photo("b", at: day1Late, poi: "海边")
    let c = photo("c", at: day2, poi: "火锅店")
    let d = photo("d", at: day2, poi: nil)
    let labels: [UUID: Set<String>] = [
        a.id: ["戏水", "沙滩", "海边"],
        b.id: ["亲子互动", "儿童"],
        c.id: ["火锅", "美食"],
        d.id: ["山脉"]
    ]
    let people: [UUID: [String]] = [a.id: ["小明"], b.id: ["小明"]]

    // 规则优先级：生日压过美食；一张图只取第一个命中的活动。
    let birthday = TrajectoryFusion.activity(for: ["生日", "蛋糕", "美食"])
    expectEqual(birthday?.title ?? "", "生日庆祝", "生日优先于美食")
    expectEqual(TrajectoryFusion.activity(for: ["山脉"])?.title ?? "", "", "风景标签不单独成为活动")

    let activities = TrajectoryFusion.activities(labelsByPhoto: labels, peopleByPhoto: people)
    expectEqual(activities.count, 3, "三张有活动的照片聚成三个活动")
    let beach = activities.first { $0.title == "海边戏水" }
    expectEqual(beach?.count ?? -1, 1, "海边戏水计一张")
    let family = activities.first { $0.title == "亲子时光" }
    expectEqual(family?.companions.first?.name ?? "", "小明", "亲子活动挂上同框人物")
    expectEqual(family?.companions.first?.count ?? -1, 1, "同一张照片的人物只记一次")

    let days = TrajectoryFusion.days(photos: [a, b, c, d],
                                     labelsByPhoto: labels,
                                     peopleByPhoto: people,
                                     calendar: calendar)
    expectEqual(days.count, 2, "按天与地点聚成两段")
    let firstDay = days.first { calendar.isDate($0.date, inSameDayAs: day1) }
    expectEqual(firstDay?.place ?? "", "海边", "地点取 POI")
    expectEqual(firstDay?.photoCount ?? -1, 2, "同一天同一地点合并计数")
    expectEqual(firstDay?.activity ?? "", "亲子时光", "同分时按规则优先级取亲子时光")
    expectEqual(firstDay?.companions.first ?? "", "小明", "轨迹片段保留同框人物")
    let secondDay = days.first { calendar.isDate($0.date, inSameDayAs: day2) }
    expectEqual(secondDay?.place ?? "", "火锅店", "第二天的地点")
    expectEqual(secondDay?.activity ?? "", "美食", "美食活动命中")
    expectEqual(secondDay?.photoCount ?? -1, 1, "没有活动的照片不进入轨迹片段")
}

runFormatChecks()
runCoordinateChecks()
runPlaceClusterChecks()
runPathChecks()
runSQLiteChecks()
runMetadataChecks()
runTrajectoryChecks()

CheckRecorder.shared.finish()
