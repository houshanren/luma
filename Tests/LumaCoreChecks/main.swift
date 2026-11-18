import Foundation
import LumaCore

/// 命令行环境没有 XCTest，这里用最小断言集跑纯逻辑检查：
/// `swift run LumaCoreChecks`，任一断言失败即以非零码退出。
private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    expect(lhs == rhs, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

private func expectClose(_ lhs: CGFloat, _ rhs: CGFloat, accuracy: CGFloat, _ message: String) {
    expect(abs(lhs - rhs) <= accuracy, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

// MARK: - ThumbnailSizing

expectEqual(ThumbnailSizing.bucket(for: 1), 128, "最小档位为 128")
expectEqual(ThumbnailSizing.bucket(for: 128), 128, "128 命中自身档位")
expectEqual(ThumbnailSizing.bucket(for: 129), 192, "129 向上取整到 192")
expectEqual(ThumbnailSizing.bucket(for: 480), 512, "480 向上取整到 512")
expectEqual(ThumbnailSizing.bucket(for: 5_000), 1024, "超出上限收敛到 1024")
expectEqual(ThumbnailSizing.quickPixel, 192, "快速层固定 192")

// MARK: - GridLayout

expectEqual(GridLayout.columns(contentWidth: 1000, targetSize: 200, spacing: 4), 4, "正方形网格列数")
expectClose(GridLayout.squareCellWidth(contentWidth: 1000, columns: 4, spacing: 4), 247,
            accuracy: 0.01, "正方形格子边长")
expectEqual(GridLayout.columns(contentWidth: 10, targetSize: 200, spacing: 4), 1, "窄容器至少一列")

let filled = GridLayout.justifiedRows(aspects: [1.5, 1.5],
                                      width: 1000,
                                      targetHeight: 500,
                                      spacing: 4)
expectEqual(filled.count, 1, "两张横图排成一行")
if let row = filled.first {
    let total = row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * 4
    expectClose(total, 1000, accuracy: 0.5, "已填满的行宽度等于容器")
    expectEqual(row.map(\.index), [0, 1], "保持原始顺序")
}

let single = GridLayout.justifiedRows(aspects: [4], width: 400, targetHeight: 300, spacing: 4)
expectEqual(single.count, 1, "单张照片一行")
if let item = single.first?.first {
    expectClose(item.width, 400, accuracy: 0.5, "单张超宽照片不越界")
    expectClose(item.height, 100, accuracy: 0.5, "高度按宽高比收敛")
}

expect(GridLayout.justifiedRows(aspects: [], width: 800, targetHeight: 200, spacing: 4).isEmpty,
       "空输入不产生行")

let longRun = GridLayout.justifiedRows(aspects: Array(repeating: 4, count: 20),
                                       width: 4000, targetHeight: 10, spacing: 0)
expect(longRun.allSatisfy { $0.count <= 8 }, "单行最多 8 张")

// MARK: - 瀑布流

let masonry = GridLayout.masonryColumns(aspects: [1, 2, 0.5, 1.5, 1, 1], columns: 3)
expectEqual(masonry.count, 3, "瀑布流列数")
expectEqual(masonry.flatMap { $0 }.sorted(), Array(0..<6), "每张照片只落进一列")
expectEqual(masonry[0], [0, 4], "每次都落到当前最矮的列")
expect(GridLayout.masonryColumns(aspects: [], columns: 3).allSatisfy(\.isEmpty),
       "空输入不产生照片")
expectEqual(GridLayout.masonryColumns(aspects: [1, 2], columns: 1), [[0, 1]],
            "单列时保持原始顺序")

// MARK: - 行程分段

let consecutive = TripSegmentation.spans(placeKeys: ["a", "a", "a"],
                                         dayOrdinals: [100, 101, 102])
expectEqual(consecutive.count, 1, "同地点连续日期合并为一段")

let gap = TripSegmentation.spans(placeKeys: ["a", "a", "a"],
                                 dayOrdinals: [100, 102, 103])
expectEqual(gap, [0...0, 1...2], "隔天即另起一段")

let moved = TripSegmentation.spans(placeKeys: ["a", "b", "b"],
                                   dayOrdinals: [100, 101, 102])
expectEqual(moved, [0...0, 1...2], "地点变化即分段")

expectEqual(TripSegmentation.spans(placeKeys: [], dayOrdinals: []), [], "空输入不产生行程段")
expectEqual(TripSegmentation.spans(placeKeys: ["a"], dayOrdinals: [1]), [0...0], "单张照片单独成段")

// MARK: - 智能美化

let darkPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.18, lumaSpread: 0.2, saturation: 0.35,
                                                red: 0.20, green: 0.18, blue: 0.17,
                                                highlightClip: 0, shadowClip: 0.12,
                                                sharpness: 130))
expect(darkPhoto.exposure > 0.3, "偏暗画面提亮")
expect(darkPhoto.shadows > 0.05, "暗部补光")
expect(darkPhoto.score > BeautyAdvisor.recommendThreshold, "偏暗照片进入推荐")
expect(darkPhoto.reasons.contains { $0.contains("偏暗") }, "理由包含偏暗")

let brightPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.86, lumaSpread: 0.3, saturation: 0.4,
                                                  red: 0.90, green: 0.86, blue: 0.82,
                                                  highlightClip: 0.18, shadowClip: 0,
                                                  sharpness: 130))
expect(brightPhoto.exposure < 0, "过亮画面压暗")
expect(brightPhoto.reasons.contains { $0.contains("偏亮") }, "理由包含偏亮")

let warmPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.45, lumaSpread: 0.24, saturation: 0.4,
                                                red: 0.52, green: 0.45, blue: 0.36,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(warmPhoto.warmth < 0, "偏暖画面回正色温")
expect(warmPhoto.reasons.contains { $0.contains("偏暖") }, "理由包含偏暖")

let coldPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.45, lumaSpread: 0.24, saturation: 0.4,
                                                red: 0.36, green: 0.45, blue: 0.52,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(coldPhoto.warmth > 0, "偏冷画面回正色温")

let flatPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.46, lumaSpread: 0.08, saturation: 0.12,
                                                red: 0.46, green: 0.46, blue: 0.46,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 130))
expect(flatPhoto.contrast > 0.05, "低对比画面提升对比度")
expect(flatPhoto.saturation > 0.05, "低饱和画面提升饱和度")

let softPhoto = BeautyAdvisor.advise(BeautyStats(luma: 0.5, lumaSpread: 0.25, saturation: 0.4,
                                                red: 0.5, green: 0.5, blue: 0.5,
                                                highlightClip: 0, shadowClip: 0,
                                                sharpness: 20))
expect(softPhoto.sharpness > 0.1, "偏软画面提升锐度")

let cleanPhoto = BeautyAdvisor.advise(BeautyStats.neutral)
expect(cleanPhoto.score < BeautyAdvisor.recommendThreshold, "正常照片不进入推荐")
expectEqual(cleanPhoto.sharpness, 0, "无需调整时不加锐化")
expectEqual(cleanPhoto.exposure, 0, "正常曝光不调整")
expect(cleanPhoto.reasons.isEmpty, "正常照片没有理由文案")

// MARK: - JPEGMetadataStripper

// 合成一个包含 APP0 / APP1 / COM 的最小 JPEG 段结构，只用于验证字节级重建。
var jpegWithMetadata: [UInt8] = [0xFF, 0xD8]
jpegWithMetadata += [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]              // APP0
jpegWithMetadata += [0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // APP1 EXIF
jpegWithMetadata += [0xFF, 0xFE, 0x00, 0x04, 0x41, 0x42]              // COM
jpegWithMetadata += [0xFF, 0xDB, 0x00, 0x04, 0x00, 0x01]              // DQT
jpegWithMetadata += [0xFF, 0xDA, 0x00, 0x02]                          // SOS
jpegWithMetadata += [0x12, 0x34, 0x56, 0xFF, 0xD9]                    // 熵数据 + EOI

var expectedStripped: [UInt8] = [0xFF, 0xD8]
expectedStripped += [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]
expectedStripped += [0xFF, 0xDB, 0x00, 0x04, 0x00, 0x01]
expectedStripped += [0xFF, 0xDA, 0x00, 0x02]
expectedStripped += [0x12, 0x34, 0x56, 0xFF, 0xD9]

let stripped = JPEGMetadataStripper.strip(Data(jpegWithMetadata))
expectEqual(stripped ?? Data(), Data(expectedStripped), "无损剥离只移除 APP1 与 COM，保留图像段与压缩数据")
expectEqual(stripped?.count ?? -1, jpegWithMetadata.count - 16, "无损剥离后体积减小且像素段不变")
expectEqual(JPEGMetadataStripper.strip(Data(expectedStripped)) ?? Data(), Data(expectedStripped),
            "没有可移除元数据时字节完全不变")
expect(JPEGMetadataStripper.strip(Data([0x00, 0x01, 0x02])) == nil, "非 JPEG 数据返回 nil")
expect(JPEGMetadataStripper.strip(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00])) == nil, "段长度不完整返回 nil")

// MARK: - 足迹回放编排

let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

func sample(_ seconds: Double, _ latitude: Double, _ longitude: Double,
            _ key: String = "a", _ name: String = "杭州") -> FootprintSample {
    FootprintSample(time: baseTime.addingTimeInterval(seconds),
                    point: FootprintPoint(latitude: latitude, longitude: longitude),
                    placeKey: key,
                    placeName: name)
}

let merged = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(60, 30.2600, 120.1300),
    sample(120, 30.2601, 120.1301)
])
expectEqual(merged.stops.count, 1, "同一位置的连拍合并成一站")
expectEqual(merged.stops.first?.photoCount, 3, "合并后保留照片数")

let nearby = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(600, 30.2610, 120.1300)
])
expectEqual(nearby.stops.count, 2, "相隔约 110 米的照片仍是两站")
expectEqual(nearby.legs.count, 1, "两站之间有一段行程")
if let leg = nearby.legs.first {
    expect(leg.distance > 90 && leg.distance < 130, "近距离行程按实际米数计算")
    expect(leg.cameraDistance < 500, "近距离行程把镜头压到街区尺度")
    expect(leg.pitch >= 45, "街区行程使用大俯仰角")
    expect(leg.caption.contains("米"), "近距离行程给出米级文案")
    expect(leg.duration >= 1.5 && leg.duration <= 2.0, "近距离行程保留可辨认的移动过程")
    expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                accuracy: 0.001, "近距离行程使用统一视觉速度")
}

let flight = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(3600, 39.9042, 116.4074, "b", "北京")
])
if let leg = flight.legs.first {
    expect(leg.distance > 1_000_000, "跨城距离为千米级")
    expect(leg.cameraDistance > leg.distance, "长距离航段镜头升到更高处")
    expect(leg.pitch <= 35, "长距离航段压低俯仰角")
    expect(leg.heading > 300 || leg.heading < 20, "北京在杭州北方，朝向接近正北")
    expect(leg.duration <= 2.5, "长距离航段有最长时长上限")
    expectClose(CGFloat(leg.distance / leg.cameraDistance / leg.duration), 0.24,
                accuracy: 0.001, "跨城与街区保持一致的画面速度")
}

let samePlaceLongStay = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(3_000, 30.2604, 120.1300),
    sample(6_000, 30.2604, 120.1301)
])
expectEqual(samePlaceLongStay.stops.count, 1, "同地点数十米内合并为一站，避免原地抖动")

let placeChange = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "杭州"),
    sample(600, 30.2700, 120.1300, "west", "西湖")
])
expectEqual(placeChange.stops.count, 2, "地点键变化时另起一站")
expectEqual(placeChange.places, ["杭州", "西湖"], "地点名按出现顺序去重")

let monotonic = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300),
    sample(600, 30.2700, 120.1300),
    sample(1200, 30.2800, 120.1300)
])
expectEqual(monotonic.distanceToStop.count, monotonic.stops.count, "累计里程与站点数一致")
expect(monotonic.distanceToStop == monotonic.distanceToStop.sorted(), "累计里程单调递增")
expectClose(CGFloat(monotonic.totalDistance), CGFloat(monotonic.distanceToStop.last ?? 0),
            accuracy: 0.001, "总里程取最后一站的累计值")

let far = FootprintPlanner.distance(from: FootprintPoint(latitude: 0, longitude: 0),
                                    to: FootprintPoint(latitude: 1, longitude: 0))
expectClose(CGFloat(far), 111_195, accuracy: 500, "一度纬度约 111 公里")

let midpoint = FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                            to: FootprintPoint(latitude: 30, longitude: 40),
                                            fraction: 0.5)
expectClose(CGFloat(midpoint.latitude), 20.28, accuracy: 0.2, "大圆插值中点纬度")
expectClose(CGFloat(midpoint.longitude), 29.35, accuracy: 0.3, "大圆插值中点经度")
expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                    to: FootprintPoint(latitude: 30, longitude: 40),
                                    fraction: -1) == FootprintPoint(latitude: 10, longitude: 20),
       "插值比例夹到 0")
expect(FootprintPlanner.interpolate(from: FootprintPoint(latitude: 10, longitude: 20),
                                    to: FootprintPoint(latitude: 30, longitude: 40),
                                    fraction: 2) == FootprintPoint(latitude: 30, longitude: 40),
       "插值比例夹到 1")

var manySamples: [FootprintSample] = []
for index in 0..<400 {
    let offset = Double(index) * 0.002
    manySamples.append(sample(Double(index) * 60, 30.0 + offset, 120.0 + offset))
}
let capped = FootprintPlanner.plan(samples: manySamples)
expect(capped.stops.count <= FootprintPlanner.maxStops, "站点数收敛到上限")
expectEqual(capped.stops.first?.point, manySamples.first?.point, "抽样保留首站")
expect(capped.stops.last?.point.latitude ?? 0 > 30.7, "抽样保留尾站")

let oneDegree = FootprintPlanner.overviewDistance(of: [
    FootprintPoint(latitude: 30, longitude: 120),
    FootprintPoint(latitude: 31, longitude: 121)
])
expect(oneDegree > 150_000, "全览镜头覆盖整段范围")

expect(FootprintPlanner.plan(samples: []).isEmpty, "没有样本时返回空计划")

// MARK: - 连续巡航时间轴

let veryShort = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "起点"),
    sample(2_000, 30.26036, 120.1300, "b", "附近")
])
expectEqual(veryShort.stops.count, 2, "约四十米且时间断开的照片保留为两站")
expect(veryShort.legs.first?.duration ?? 0 >= 0.85, "极短行程也有最短可辨认时长")

let cruisePlan = FootprintPlanner.plan(samples: [
    sample(0, 30.2600, 120.1300, "a", "第一站"),
    sample(600, 30.2620, 120.1300, "b", "第二站"),
    sample(660, 30.2620, 120.1300, "b", "第二站"),
    sample(1_500, 30.2640, 120.1300, "c", "第三站"),
    sample(1_560, 30.2640, 120.1300, "c", "第三站")
])
let cruise = FootprintCruiseTimeline(plan: cruisePlan)
let expectedDuration = cruisePlan.legs.reduce(0) { $0 + $1.duration + $1.dwell }
expectClose(CGFloat(cruise.totalDuration), CGFloat(expectedDuration),
            accuracy: 0.0001, "总时长包含所有行进与旅拍停留")

if let firstLeg = cruisePlan.legs.first {
    let middle = cruise.frame(at: firstLeg.duration * 0.5)
    expectClose(CGFloat(middle.legFraction), 0.5, accuracy: 0.0001,
                "行进段中点使用未经缓动的线性比例")
    expectEqual(middle.head,
                FootprintPlanner.interpolate(from: cruisePlan.stops[0].point,
                                             to: cruisePlan.stops[1].point,
                                             fraction: 0.5),
                "光点与线性行程比例同步")

    let arrival = cruise.frame(at: firstLeg.duration)
    let dwelling = cruise.frame(at: firstLeg.duration + firstLeg.dwell * 0.5)
    expect(arrival.isDwelling, "抵达照片较多的站点后进入旅拍停留")
    expectEqual(dwelling.head, cruisePlan.stops[1].point, "停留期间光点保持不动")
    expectClose(CGFloat(dwelling.dwellFraction), 0.5, accuracy: 0.0001,
                "停留进度也在统一时间轴中")

    let departure = cruise.frame(at: cruise.time(atStop: 1))
    expectEqual(arrival.cameraCenter, departure.cameraCenter, "跨段时镜头中心不跳变")
    expectClose(CGFloat(arrival.cameraDistance), CGFloat(departure.cameraDistance),
                accuracy: 0.0001, "跨段时镜头高度连续")
    expectClose(CGFloat(arrival.pitch), CGFloat(departure.pitch),
                accuracy: 0.0001, "跨段时俯仰角连续")
    expectClose(CGFloat(arrival.heading), CGFloat(departure.heading),
                accuracy: 0.0001, "跨段时航向连续")
    expectEqual(arrival.head, departure.head, "跨段时光点位置连续")
    expect(!departure.isDwelling, "停留结束后直接进入下一段行进")
}

expectClose(CGFloat(cruise.time(atStop: 0)), 0, accuracy: 0.0001,
            "首站映射到时间轴起点")
if let lastLeg = cruisePlan.legs.last {
    expectClose(CGFloat(cruise.time(atStop: cruisePlan.stops.count - 1)),
                CGFloat(cruise.totalDuration - lastLeg.dwell),
                accuracy: 0.0001, "末站映射到抵达时刻而非整个时间轴末尾")
    let finalDwell = cruise.frame(at: cruise.totalDuration - lastLeg.dwell * 0.5)
    expect(finalDwell.isDwelling, "末尾旅拍停留不会提前结束旅程")
}
let completed = cruise.frame(at: cruise.totalDuration)
expect(completed.isComplete, "时间轴末尾返回完成状态")
expectEqual(completed.head, cruisePlan.stops.last?.point, "完成时光点停在最后一站")

let wrapPlan = FootprintPlanner.plan(samples: [
    sample(0, 30.0, 120.0, "a", "起点"),
    sample(600, 30.01, 119.999, "b", "西北"),
    sample(1_200, 30.02, 120.0, "c", "东北")
])
let wrapCruise = FootprintCruiseTimeline(plan: wrapPlan)
if wrapPlan.legs.count == 2 {
    let middle = wrapCruise.frame(at: wrapCruise.time(atStop: 1) + wrapPlan.legs[1].duration * 0.5)
    expect(middle.heading > 350 || middle.heading < 10, "跨段航向走最短圆弧，不从三百五十度反转半圈")
}

let emptyCruise = FootprintCruiseTimeline(plan: FootprintPlanner.plan(samples: []))
expectEqual(emptyCruise.totalDuration, 0, "空计划时间轴为零时长")
expect(emptyCruise.frame(at: 0).isComplete, "空计划直接完成")
let singleCruise = FootprintCruiseTimeline(plan: merged)
expectEqual(singleCruise.totalDuration, 0, "单站计划没有行进时长")
expect(singleCruise.frame(at: 0).isComplete, "单站计划直接完成")
expectEqual(singleCruise.frame(at: 0).head, merged.stops.first?.point, "单站光点固定在唯一站点")

// MARK: - 票据 / 证件文字判定

expect(DocumentText.isValidChineseID("11010519491231002X"), "合法 18 位身份证号（校验位 X）")
expect(!DocumentText.isValidChineseID("110105194912310021"), "校验位错误时不算合法")
expect(!DocumentText.isValidChineseID("11010519491231002"), "位数不足不算合法")
expect(!DocumentText.isValidChineseID("11010519491331002X"), "出生月份非法不算合法")
expect(DocumentText.isValidChineseID("１１０１０５１９４９１２３１００２Ｘ"), "全角数字先归一化成 ASCII 再校验")

expect(DocumentText.looksLikeIDCard("姓名 张三\n公民身份号码 11010519491231002X\n签发机关 北京市公安局"),
       "身份证字段名 + 合法号码")
expect(DocumentText.looksLikeIDCard("居民身份证"), "只出现证件标题也判定为证件")
expect(!DocumentText.looksLikeIDCard("请把身份证拍照发我"), "聊天截图里的「身份证」不算证件")

expect(DocumentText.looksLikeInvoice("增值税电子普通发票\n发票代码 011002100311\n价税合计 ¥99.00"),
       "发票强特征词命中")
expect(!DocumentText.looksLikeInvoice("今天去景区买了门票，收据放在包里"), "普通票据不算发票")
expect(!DocumentText.looksLikeInvoice(""), "空文本不算发票")

// MARK: - 地标表

expectEqual(LandmarkCatalog.nearest(latitude: 39.9163, longitude: 116.3972)?.name, "故宫",
            "坐标命中故宫")
expectEqual(LandmarkCatalog.nearest(latitude: 30.2431, longitude: 120.1487)?.name, "西湖",
            "坐标命中西湖")
expect(LandmarkCatalog.nearest(latitude: 0, longitude: 0) == nil, "没有地标的海域返回 nil")
expect(LandmarkCatalog.nearest(latitude: 30.0, longitude: 120.0) == nil,
       "距离西湖约 27 公里超过半径不算命中")
expectEqual(LandmarkCatalog.match(placeText: "浙江省杭州市西湖风景名胜区")?.name, "西湖",
            "POI 文字命中西湖")
expectEqual(LandmarkCatalog.match(placeText: "台北故宫博物院")?.name, "台北故宫博物院",
            "同时含「故宫」时取最长命中")
expectEqual(LandmarkCatalog.match(placeText: "北京市东城区景山前街4号 故宫")?.name, "故宫",
            "地址里的故宫可命中")
expect(LandmarkCatalog.match(placeText: "浦东新区张江路") == nil, "普通地址不命中地标")
if let palace = LandmarkCatalog.match(placeText: "故宫") {
    expect(LandmarkCatalog.distance(latitude: 39.9163, longitude: 116.3972, to: palace) < 1,
           "与地标同坐标时距离为 0")
}

// MARK: - 感知哈希

let flatGray = Array(repeating: UInt8(128), count: 9 * 8)
expectEqual(PerceptualHash.dHash(grayscale: flatGray), 0, "纯色图 dHash 为 0")

var decreasing: [UInt8] = []
var increasing: [UInt8] = []
for index in 0..<(9 * 8) {
    let column = index % 9
    decreasing.append(UInt8(255 - column * 20))
    increasing.append(UInt8(column * 20))
}
expectEqual(PerceptualHash.dHash(grayscale: decreasing), Int64(bitPattern: UInt64.max),
            "每行从左到右递减时 64 位全为 1")
expectEqual(PerceptualHash.dHash(grayscale: increasing), 0, "每行从左到右递增时 64 位全为 0")
expectEqual(PerceptualHash.hammingDistance(0, 0), 0, "相同哈希距离为 0")
expectEqual(PerceptualHash.hammingDistance(0, Int64(bitPattern: UInt64.max)), 64,
            "全 0 与全 1 距离为 64")
expect(PerceptualHash.isSimilar(0, 0b1111111111), "10 位以内视为相似")
expect(!PerceptualHash.isSimilar(0, Int64(bitPattern: 0b11111111111)), "超过阈值不相似")
expect(PerceptualHash.dHash(grayscale: [0, 1, 2]) == nil, "灰度数据不足返回 nil")

// MARK: - 结果

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
