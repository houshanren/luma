import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runMediaInsightChecks() {

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

}
