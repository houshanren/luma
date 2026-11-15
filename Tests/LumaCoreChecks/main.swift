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

// MARK: - 结果

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
