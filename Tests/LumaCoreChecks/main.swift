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

// MARK: - 结果

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
