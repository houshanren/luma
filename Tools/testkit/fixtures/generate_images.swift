// 拾光 Luma 测试集 · 图片素材生成器
//
// 只依赖 macOS 自带的 ImageIO / CoreGraphics / CoreText：
// - 生成带 EXIF（拍摄时间 / 相机 / 镜头 / GPS）的照片，覆盖旅行、城市、海邊、聚会等场景；
// - 生成截屏、全景、竖幅、模糊、近似重复、损坏文件等回归素材；
// - 生成实况照片的 JPEG 端（同名 MOV 由 testkit.py 用 ffmpeg 生成）；
// - 按 JSON 配置生成网络影院 / 影院的竖版海报和横版背景图。
//
// 用法：
//   swiftc -O Tools/testkit/fixtures/generate_images.swift -o /tmp/luma-fixture-images
//   /tmp/luma-fixture-images --out ~/Movies/LumaTestKit/dataset [--posters-json posters.json] [--force]
//
// 产物与说明写入 <out>/image_manifest.json，由 testkit.py 合并进总清单。

import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 随机

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFFFFFF) / Double(0xFFFFFFFF)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let value = next()
        return range.lowerBound + Int(value * Double(range.upperBound - range.lowerBound + 1))
    }
}

// MARK: - 色板

private struct Palette {
    let name: String
    let top: NSColor
    let bottom: NSColor
    let glow: NSColor
    let hillA: NSColor
    let hillB: NSColor
    let accent: NSColor
}

private let palettes: [Palette] = [
    Palette(name: "spring",
            top: NSColor(calibratedRed: 0.46, green: 0.72, blue: 0.86, alpha: 1),
            bottom: NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.62, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.55, alpha: 1),
            hillA: NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.32, alpha: 1),
            hillB: NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.22, alpha: 1),
            accent: NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.32, alpha: 1)),
    Palette(name: "harbor",
            top: NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.70, alpha: 1),
            bottom: NSColor(calibratedRed: 0.72, green: 0.90, blue: 0.93, alpha: 1),
            glow: NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.82, alpha: 1),
            hillA: NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.50, alpha: 1),
            hillB: NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.36, alpha: 1),
            accent: NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.82, alpha: 1)),
    Palette(name: "city",
            top: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.28, alpha: 1),
            bottom: NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.42, alpha: 1),
            glow: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.35, alpha: 1),
            hillA: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.18, alpha: 1),
            hillB: NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.10, alpha: 1),
            accent: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.35, alpha: 1)),
    Palette(name: "amber",
            top: NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.30, alpha: 1),
            bottom: NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.52, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.70, alpha: 1),
            hillA: NSColor(calibratedRed: 0.50, green: 0.24, blue: 0.18, alpha: 1),
            hillB: NSColor(calibratedRed: 0.34, green: 0.14, blue: 0.12, alpha: 1),
            accent: NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.38, alpha: 1)),
    Palette(name: "forest",
            top: NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.36, alpha: 1),
            bottom: NSColor(calibratedRed: 0.62, green: 0.74, blue: 0.56, alpha: 1),
            glow: NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.70, alpha: 1),
            hillA: NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.22, alpha: 1),
            hillB: NSColor(calibratedRed: 0.06, green: 0.18, blue: 0.14, alpha: 1),
            accent: NSColor(calibratedRed: 0.74, green: 0.78, blue: 0.36, alpha: 1)),
    Palette(name: "paris",
            top: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.80, alpha: 1),
            bottom: NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.64, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.66, alpha: 1),
            hillA: NSColor(calibratedRed: 0.32, green: 0.34, blue: 0.42, alpha: 1),
            hillB: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.32, alpha: 1),
            accent: NSColor(calibratedRed: 0.96, green: 0.68, blue: 0.42, alpha: 1)),
    Palette(name: "kyoto",
            top: NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.70, alpha: 1),
            bottom: NSColor(calibratedRed: 0.99, green: 0.88, blue: 0.78, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.78, alpha: 1),
            hillA: NSColor(calibratedRed: 0.50, green: 0.30, blue: 0.34, alpha: 1),
            hillB: NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.26, alpha: 1),
            accent: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.72, alpha: 1)),
    Palette(name: "santorini",
            top: NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.86, alpha: 1),
            bottom: NSColor(calibratedRed: 0.80, green: 0.90, blue: 0.98, alpha: 1),
            glow: NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.82, alpha: 1),
            hillA: NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1),
            hillB: NSColor(calibratedRed: 0.24, green: 0.44, blue: 0.72, alpha: 1),
            accent: NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.72, alpha: 1)),
    Palette(name: "snow",
            top: NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.78, alpha: 1),
            bottom: NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.98, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.94, alpha: 1),
            hillA: NSColor(calibratedRed: 0.74, green: 0.80, blue: 0.88, alpha: 1),
            hillB: NSColor(calibratedRed: 0.52, green: 0.60, blue: 0.72, alpha: 1),
            accent: NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.00, alpha: 1)),
    Palette(name: "reef",
            top: NSColor(calibratedRed: 0.36, green: 0.76, blue: 0.82, alpha: 1),
            bottom: NSColor(calibratedRed: 0.08, green: 0.46, blue: 0.58, alpha: 1),
            glow: NSColor(calibratedRed: 0.95, green: 0.98, blue: 0.86, alpha: 1),
            hillA: NSColor(calibratedRed: 0.04, green: 0.30, blue: 0.42, alpha: 1),
            hillB: NSColor(calibratedRed: 0.02, green: 0.20, blue: 0.32, alpha: 1),
            accent: NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.44, alpha: 1)),
    Palette(name: "desert",
            top: NSColor(calibratedRed: 0.90, green: 0.70, blue: 0.46, alpha: 1),
            bottom: NSColor(calibratedRed: 0.99, green: 0.88, blue: 0.68, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.76, alpha: 1),
            hillA: NSColor(calibratedRed: 0.58, green: 0.40, blue: 0.26, alpha: 1),
            hillB: NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.18, alpha: 1),
            accent: NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.34, alpha: 1)),
    Palette(name: "golden",
            top: NSColor(calibratedRed: 0.34, green: 0.34, blue: 0.56, alpha: 1),
            bottom: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.44, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.52, alpha: 1),
            hillA: NSColor(calibratedRed: 0.24, green: 0.22, blue: 0.32, alpha: 1),
            hillB: NSColor(calibratedRed: 0.14, green: 0.12, blue: 0.20, alpha: 1),
            accent: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.36, alpha: 1)),
    Palette(name: "home",
            top: NSColor(calibratedRed: 0.96, green: 0.88, blue: 0.76, alpha: 1),
            bottom: NSColor(calibratedRed: 0.82, green: 0.68, blue: 0.56, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.62, alpha: 1),
            hillA: NSColor(calibratedRed: 0.52, green: 0.38, blue: 0.30, alpha: 1),
            hillB: NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.18, alpha: 1),
            accent: NSColor(calibratedRed: 0.92, green: 0.62, blue: 0.36, alpha: 1)),
    Palette(name: "jiuzhai",
            top: NSColor(calibratedRed: 0.30, green: 0.52, blue: 0.52, alpha: 1),
            bottom: NSColor(calibratedRed: 0.06, green: 0.46, blue: 0.46, alpha: 1),
            glow: NSColor(calibratedRed: 0.94, green: 0.90, blue: 0.70, alpha: 1),
            hillA: NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.26, alpha: 1),
            hillB: NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.20, alpha: 1),
            accent: NSColor(calibratedRed: 0.30, green: 0.76, blue: 0.68, alpha: 1)),
    Palette(name: "pool",
            top: NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.90, alpha: 1),
            bottom: NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.98, alpha: 1),
            glow: NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.80, alpha: 1),
            hillA: NSColor(calibratedRed: 0.10, green: 0.52, blue: 0.68, alpha: 1),
            hillB: NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.54, alpha: 1),
            accent: NSColor(calibratedRed: 0.98, green: 0.54, blue: 0.34, alpha: 1))
]

private func palette(named name: String) -> Palette {
    palettes.first { $0.name == name } ?? palettes[0]
}

// MARK: - 绘制

/// 复用一个 CIContext：规模模式要处理上千张图，每次新建代价很高。
private let sharedBlurContext = CIContext(options: [.useSoftwareRenderer: false])

private func makeContext(width: Int, height: Int) -> CGContext {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context
}

private func fillGradient(_ context: CGContext, rect: CGRect, top: NSColor, bottom: NSColor) {
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
}

private func drawGlow(_ context: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
    let colors = [color.withAlphaComponent(0.95).cgColor,
                  color.withAlphaComponent(0.0).cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}

private func drawHills(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    var rng = SeededRandom(seed: seed)
    for layer in 0..<2 {
        let baseY = rect.height * (layer == 0 ? 0.42 : 0.30)
        let amplitude = rect.height * (layer == 0 ? 0.10 : 0.07)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: baseY))
        var x: CGFloat = 0
        while x <= rect.width {
            let wave = CGFloat(sin(Double(x / rect.width * 4 + CGFloat(rng.next()) * 0.4)))
            path.addLine(to: CGPoint(x: x, y: baseY + wave * amplitude))
            x += rect.width / 12
        }
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()
        context.setFillColor((layer == 0 ? palette.hillA : palette.hillB).cgColor)
        context.addPath(path)
        context.fillPath()
    }
}

private func drawCity(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    var rng = SeededRandom(seed: seed)
    var x: CGFloat = -10
    while x < rect.width {
        let width = CGFloat(rng.int(40...110))
        let height = CGFloat(rng.int(80...360))
        let building = CGRect(x: x, y: 0, width: width, height: height)
        context.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.92).cgColor)
        context.fill(building)
        // 窗户：偶数格亮起。
        var wy: CGFloat = 16
        while wy < height - 20 {
            var wx: CGFloat = 12
            while wx < width - 10 {
                if rng.next() > 0.45 {
                    context.setFillColor(palette.accent.withAlphaComponent(0.75).cgColor)
                    context.fill(CGRect(x: x + wx, y: wy, width: 6, height: 9))
                }
                wx += 16
            }
            wy += 20
        }
        x += width + CGFloat(rng.int(8...26))
    }
}

private func drawBokeh(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64, count: Int) {
    var rng = SeededRandom(seed: seed)
    for _ in 0..<count {
        let radius = CGFloat(rng.int(10...70))
        let center = CGPoint(x: CGFloat(rng.next()) * rect.width,
                             y: CGFloat(rng.next()) * rect.height)
        let color = rng.next() > 0.5 ? palette.glow : palette.accent
        context.setFillColor(color.withAlphaComponent(0.05 + CGFloat(rng.next()) * 0.10).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
    }
}

private func drawGrain(_ context: CGContext, rect: CGRect, seed: UInt64) {
    var rng = SeededRandom(seed: seed &+ 99)
    // 控制在 3000 点以内：缩略图看不出噪点，但能避免画面过于「塑料」。
    for _ in 0..<3000 {
        let x = CGFloat(rng.next()) * rect.width
        let y = CGFloat(rng.next()) * rect.height
        let alpha = CGFloat(rng.next()) * 0.05
        context.setFillColor(NSColor(calibratedWhite: rng.next() > 0.5 ? 1 : 0, alpha: alpha).cgColor)
        context.fill(CGRect(x: x, y: y, width: 1.4, height: 1.4))
    }
}

private func drawVignette(_ context: CGContext, rect: CGRect) {
    let colors = [NSColor.clear.cgColor,
                  NSColor(calibratedWhite: 0, alpha: 0.22).cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.55, 1]) else { return }
    context.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: rect.width * 0.2,
                               endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.8,
                               options: [])
}

private func drawText(_ context: CGContext, _ text: String, at point: CGPoint,
                      size: CGFloat, weight: NSFont.Weight = .bold,
                      color: NSColor = .white, maxWidth: CGFloat? = nil) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    if let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
        // 简易截断：按字符逼近，避免海报标题溢出。
        var cut = text
        while !cut.isEmpty {
            cut.removeLast()
            let probe = NSAttributedString(string: cut + "…", attributes: attributes)
            if CTLineGetTypographicBounds(CTLineCreateWithAttributedString(probe), nil, nil, nil) <= Double(maxWidth) {
                break
            }
        }
        let probe = NSAttributedString(string: cut + "…", attributes: attributes)
        CTLineDraw(CTLineCreateWithAttributedString(probe), context)
        return
    }
    CTLineDraw(line, context)
}

// MARK: - 旅行场景

/// 2010–2026 家庭环球旅行的取景地。每个场景只保留可识别轮廓，
/// 重点是「一家人出现在地标前」，而不是照片级还原。
private enum TripScene: Equatable {
    case skyline          // 香港维港 / 纽约 / 新加坡天际线
    case castle           // 迪士尼城堡
    case greatWall        // 长城
    case chineseGate      // 天安门 / 景福宫
    case thaiPalace       // 曼谷大皇宫
    case beach            // 三亚 / 巴厘岛
    case karst            // 桂林漓江
    case warriors         // 兵马俑
    case islandChurch     // 鼓浪屿
    case cherryPagoda     // 京都清水寺
    case fuji             // 富士山
    case merlion          // 新加坡鱼尾狮
    case seaTemple        // 巴厘岛海神庙
    case snowCanal        // 北海道小樽
    case eiffel           // 巴黎铁塔
    case louvre           // 卢浮宫金字塔
    case towerBridge      // 伦敦塔桥
    case colosseum        // 罗马斗兽场
    case canalBoat        // 威尼斯贡多拉
    case alps             // 瑞士雪山
    case santorini        // 圣托里尼
    case windmill         // 阿姆斯特丹风车
    case liberty          // 纽约自由女神
    case timesSquare      // 纽约时代广场
    case goldenGate       // 旧金山金门大桥
    case geyser           // 黄石大棱镜
    case operaHouse       // 悉尼歌剧院
    case reef             // 大堡礁
    case lakeJetty        // 皇后镇湖湾
    case tokyoTower       // 东京塔重逢
    // 日常与国内
    case homeDinner       // 年夜饭 / 客厅
    case schoolGate       // 上学第一天 / 校门口
    case park             // 小区公园
    case supermarket      // 超市采购
    case office           // 爸爸的办公室
    case birthday         // 客厅生日会
    case graduation       // 毕业合影
    case piano            // 钢琴课
    case classroom        // 培训班 / 教室
    case sportsDay        // 学校运动会
    case safari           // 长隆野生动物世界
    case waterPark        // 长隆水上乐园
    case wedding          // 亲戚婚礼
    case study            // 周末写作业
    case jiuzhaigou       // 九寨沟彩池
    case potala           // 西藏布达拉宫
    case zhangjiajie      // 张家界石柱
    case huangshan        // 黄山云海
    case familyPortrait   // 全家福
    case castleNight      // 迪士尼烟花
}

private func ink(_ alpha: CGFloat = 0.9) -> NSColor {
    NSColor(calibratedWhite: 0.04, alpha: alpha)
}

private func drawSun(_ context: CGContext, rect: CGRect, palette: Palette, x: CGFloat, y: CGFloat) {
    drawGlow(context, center: CGPoint(x: rect.width * x, y: rect.height * y),
             radius: rect.width * 0.42, color: palette.glow)
    context.setFillColor(palette.glow.withAlphaComponent(0.92).cgColor)
    let radius = rect.width * 0.035
    context.fillEllipse(in: CGRect(x: rect.width * x - radius, y: rect.height * y - radius,
                                   width: radius * 2, height: radius * 2))
}

private func drawSea(_ context: CGContext, rect: CGRect, palette: Palette, horizon: CGFloat) {
    let y = rect.height * horizon
    context.setFillColor(palette.hillB.withAlphaComponent(0.55).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: y))
    // 波光：横向亮线，越靠下越稀。
    for index in 0..<14 {
        let lineY = y * CGFloat(index) / 14 + y * 0.05
        context.setFillColor(palette.glow.withAlphaComponent(0.10).cgColor)
        context.fill(CGRect(x: rect.width * 0.08, y: lineY,
                            width: rect.width * (0.5 + CGFloat(index % 4) * 0.1), height: 1.6))
    }
}

private func drawRidge(_ context: CGContext, rect: CGRect, palette: Palette,
                       baseY: CGFloat, height: CGFloat, peaks: [CGFloat], color: NSColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: rect.height * baseY))
    let step = rect.width / CGFloat(max(1, peaks.count - 1))
    for (index, factor) in peaks.enumerated() {
        let x = CGFloat(index) * step
        path.addLine(to: CGPoint(x: x, y: rect.height * (baseY + height * factor)))
    }
    path.addLine(to: CGPoint(x: rect.width, y: rect.height * baseY))
    path.addLine(to: CGPoint(x: rect.width, y: 0))
    path.closeSubpath()
    context.setFillColor(color.cgColor)
    context.addPath(path)
    context.fillPath()
}

private func drawFuji(_ context: CGContext, rect: CGRect, palette: Palette,
                      centerX: CGFloat, baseY: CGFloat, height: CGFloat) {
    let width = height * 1.9
    let cx = rect.width * centerX
    let base = rect.height * baseY
    let top = base + rect.height * height
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - width * 0.5, y: base))
    path.addQuadCurve(to: CGPoint(x: cx - width * 0.09, y: top),
                      control: CGPoint(x: cx - width * 0.36, y: base + (top - base) * 0.55))
    path.addLine(to: CGPoint(x: cx + width * 0.09, y: top))
    path.addQuadCurve(to: CGPoint(x: cx + width * 0.5, y: base),
                      control: CGPoint(x: cx + width * 0.36, y: base + (top - base) * 0.55))
    path.closeSubpath()
    context.setFillColor(palette.hillA.withAlphaComponent(0.9).cgColor)
    context.addPath(path)
    context.fillPath()
    // 雪顶：顶部一小段白色多边形。
    let snow = CGMutablePath()
    snow.move(to: CGPoint(x: cx - width * 0.16, y: top - rect.height * 0.035))
    snow.addLine(to: CGPoint(x: cx - width * 0.09, y: top))
    snow.addLine(to: CGPoint(x: cx + width * 0.09, y: top))
    snow.addLine(to: CGPoint(x: cx + width * 0.17, y: top - rect.height * 0.035))
    snow.addLine(to: CGPoint(x: cx + width * 0.10, y: top - rect.height * 0.015))
    snow.addLine(to: CGPoint(x: cx + width * 0.04, y: top - rect.height * 0.05))
    snow.addLine(to: CGPoint(x: cx - width * 0.02, y: top - rect.height * 0.02))
    snow.addLine(to: CGPoint(x: cx - width * 0.09, y: top - rect.height * 0.05))
    snow.closeSubpath()
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.92).cgColor)
    context.addPath(snow)
    context.fillPath()
}

/// 铁塔：两条外扩塔腿 + 上层塔身 + 平台，留出腿部空隙才像埃菲尔 / 东京塔。
private func drawLatticeTower(_ context: CGContext, rect: CGRect, centerX: CGFloat,
                              baseY: CGFloat, height: CGFloat, width: CGFloat,
                              color: NSColor, deckCount: Int = 3, curved: Bool = false) {
    let unit = min(rect.width, rect.height)
    let cx = rect.width * centerX
    let base = rect.height * baseY
    let top = base + rect.height * height
    let halfBase = unit * width * 0.5
    let halfDeck = halfBase * 0.34
    let halfTop = halfBase * 0.05
    let deckY = base + (top - base) * 0.30

    // 两条塔腿：外侧向外弯，内侧留出拱形空隙。
    for side in [CGFloat(-1), CGFloat(1)] {
        let leg = CGMutablePath()
        leg.move(to: CGPoint(x: cx + side * halfBase, y: base))
        if curved {
            leg.addQuadCurve(to: CGPoint(x: cx + side * halfDeck, y: deckY),
                             control: CGPoint(x: cx + side * halfBase * 0.72, y: base + (deckY - base) * 0.55))
            leg.addQuadCurve(to: CGPoint(x: cx + side * halfDeck * 0.42, y: base),
                             control: CGPoint(x: cx + side * halfDeck * 0.30, y: base + (deckY - base) * 0.62))
        } else {
            leg.addLine(to: CGPoint(x: cx + side * halfDeck, y: deckY))
            leg.addLine(to: CGPoint(x: cx + side * halfDeck * 0.30, y: base))
        }
        leg.closeSubpath()
        context.setFillColor(color.withAlphaComponent(0.92).cgColor)
        context.addPath(leg)
        context.fillPath()
    }

    // 上层塔身。
    let body = CGMutablePath()
    body.move(to: CGPoint(x: cx - halfDeck, y: deckY))
    body.addLine(to: CGPoint(x: cx - halfTop, y: top))
    body.addLine(to: CGPoint(x: cx + halfTop, y: top))
    body.addLine(to: CGPoint(x: cx + halfDeck, y: deckY))
    body.closeSubpath()
    context.setFillColor(color.cgColor)
    context.addPath(body)
    context.fillPath()

    // 平台与塔尖。
    for level in 0..<max(2, deckCount) {
        let ratio = 0.30 + CGFloat(level) * 0.22
        let y = base + (top - base) * ratio
        let half = halfDeck * (1 - ratio * 0.55)
        context.fill(CGRect(x: cx - half * 1.25, y: y,
                            width: half * 2.5, height: max(1.5, unit * 0.005)))
    }
    context.fill(CGRect(x: cx - unit * 0.003, y: top,
                        width: unit * 0.006, height: unit * 0.035))

    // 斜向桁架：少量细线就足够读出「铁塔」。
    context.setStrokeColor(color.withAlphaComponent(0.35).cgColor)
    context.setLineWidth(max(1, unit * 0.002))
    for index in 0..<7 {
        let ratio = 0.32 + CGFloat(index) * 0.09
        let y = base + (top - base) * ratio
        let half = halfDeck * (1 - ratio * 0.55)
        context.move(to: CGPoint(x: cx - half, y: y))
        context.addLine(to: CGPoint(x: cx + half, y: y + (top - base) * 0.02))
        context.strokePath()
    }
}

private func drawPagoda(_ context: CGContext, rect: CGRect, palette: Palette,
                        centerX: CGFloat, baseY: CGFloat, tiers: Int, color: NSColor) {
    let cx = rect.width * centerX
    var y = rect.height * baseY
    let tierHeight = rect.height * 0.075
    let baseWidth = rect.width * 0.16
    for level in 0..<tiers {
        let ratio = 1 - CGFloat(level) * 0.13
        let width = baseWidth * ratio
        // 飞檐：扁梯形。
        let roof = CGMutablePath()
        roof.move(to: CGPoint(x: cx - width * 0.5, y: y))
        roof.addLine(to: CGPoint(x: cx - width * 0.80, y: y + tierHeight * 0.42))
        roof.addLine(to: CGPoint(x: cx + width * 0.80, y: y + tierHeight * 0.42))
        roof.addLine(to: CGPoint(x: cx + width * 0.5, y: y))
        roof.closeSubpath()
        context.setFillColor(color.cgColor)
        context.addPath(roof)
        context.fillPath()
        // 塔身。
        context.setFillColor(color.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: cx - width * 0.30, y: y - tierHeight * 0.55,
                            width: width * 0.60, height: tierHeight * 0.55))
        y += tierHeight * 0.95
    }
    // 塔刹。
    context.fill(CGRect(x: cx - rect.width * 0.004, y: y,
                        width: rect.width * 0.008, height: rect.height * 0.05))
}

private func drawRoofGate(_ context: CGContext, rect: CGRect, palette: Palette,
                          baseY: CGFloat, roof: NSColor, wall: NSColor, tiers: Int) {
    let base = rect.height * baseY
    let width = rect.width * 0.62
    let x = (rect.width - width) / 2
    let wallHeight = rect.height * 0.11
    context.setFillColor(wall.cgColor)
    context.fill(CGRect(x: x, y: base, width: width, height: wallHeight))
    // 门洞。
    context.setFillColor(ink(0.65).cgColor)
    let doorWidth = width * 0.14
    context.fill(CGRect(x: rect.midX - doorWidth / 2, y: base, width: doorWidth, height: wallHeight * 0.62))
    // 重檐。
    var y = base + wallHeight
    for level in 0..<tiers {
        let spread = width * (1.12 - CGFloat(level) * 0.18)
        let height = rect.height * (0.045 - CGFloat(level) * 0.006)
        let roofPath = CGMutablePath()
        roofPath.move(to: CGPoint(x: rect.midX - spread * 0.5, y: y))
        roofPath.addQuadCurve(to: CGPoint(x: rect.midX, y: y + height),
                              control: CGPoint(x: rect.midX - spread * 0.25, y: y + height * 0.85))
        roofPath.addQuadCurve(to: CGPoint(x: rect.midX + spread * 0.5, y: y),
                              control: CGPoint(x: rect.midX + spread * 0.25, y: y + height * 0.85))
        roofPath.closeSubpath()
        context.setFillColor(roof.cgColor)
        context.addPath(roofPath)
        context.fillPath()
        y += height * 0.72
    }
}

private func drawGreatWall(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 远山。
    drawRidge(context, rect: rect, palette: palette, baseY: 0.26, height: 0.20,
              peaks: [0.25, 0.75, 0.35, 0.9, 0.4, 0.7, 0.3],
              color: palette.hillA.withAlphaComponent(0.75))
    drawRidge(context, rect: rect, palette: palette, baseY: 0.20, height: 0.16,
              peaks: [0.15, 0.55, 0.25, 0.7, 0.2, 0.45, 0.12],
              color: palette.hillB.withAlphaComponent(0.9))
    // 城墙：沿山脊的石带 + 两座敌楼。
    let wall = CGMutablePath()
    wall.move(to: CGPoint(x: 0, y: rect.height * 0.20))
    wall.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height * 0.30),
                      control: CGPoint(x: rect.width * 0.5, y: rect.height * 0.16))
    wall.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.265))
    wall.addQuadCurve(to: CGPoint(x: 0, y: rect.height * 0.165),
                      control: CGPoint(x: rect.width * 0.5, y: rect.height * 0.125))
    wall.closeSubpath()
    context.setFillColor(ink(0.72).cgColor)
    context.addPath(wall)
    context.fillPath()
    for ratio in [0.28, 0.68] {
        let x = rect.width * ratio
        let y = rect.height * (0.22 + ratio * 0.07)
        context.fill(CGRect(x: x - rect.width * 0.025, y: y,
                            width: rect.width * 0.05, height: rect.height * 0.075))
        context.fill(CGRect(x: x - rect.width * 0.031, y: y + rect.height * 0.075,
                            width: rect.width * 0.062, height: rect.height * 0.018))
    }
}

private func drawCastle(_ context: CGContext, rect: CGRect, palette: Palette) {
    let base = rect.height * 0.22
    let color = ink(0.78)
    let centerWidth = rect.width * 0.16
    let centerHeight = rect.height * 0.36
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: rect.midX - centerWidth / 2, y: base,
                        width: centerWidth, height: centerHeight))
    // 尖顶。
    let roof = CGMutablePath()
    roof.move(to: CGPoint(x: rect.midX - centerWidth * 0.62, y: base + centerHeight))
    roof.addLine(to: CGPoint(x: rect.midX, y: base + centerHeight + rect.height * 0.16))
    roof.addLine(to: CGPoint(x: rect.midX + centerWidth * 0.62, y: base + centerHeight))
    roof.closeSubpath()
    context.addPath(roof)
    context.fillPath()
    // 两侧塔楼。
    for side in [-1.0, 1.0] {
        let x = rect.midX + CGFloat(side) * centerWidth * 1.15
        let width = centerWidth * 0.62
        let height = centerHeight * 0.66
        context.fill(CGRect(x: x - width / 2, y: base, width: width, height: height))
        let sideRoof = CGMutablePath()
        sideRoof.move(to: CGPoint(x: x - width * 0.62, y: base + height))
        sideRoof.addLine(to: CGPoint(x: x, y: base + height + rect.height * 0.10))
        sideRoof.addLine(to: CGPoint(x: x + width * 0.62, y: base + height))
        sideRoof.closeSubpath()
        context.addPath(sideRoof)
        context.fillPath()
    }
    // 窗光。
    context.setFillColor(palette.glow.withAlphaComponent(0.85).cgColor)
    for index in 0..<3 {
        let y = base + centerHeight * (0.25 + CGFloat(index) * 0.2)
        context.fill(CGRect(x: rect.midX - rect.width * 0.012, y: y,
                            width: rect.width * 0.024, height: rect.height * 0.03))
    }
}

private func drawPyramid(_ context: CGContext, rect: CGRect, palette: Palette,
                         centerX: CGFloat, baseY: CGFloat, width: CGFloat, height: CGFloat) {
    let cx = rect.width * centerX
    let base = rect.height * baseY
    let half = rect.width * width * 0.5
    let top = base + rect.height * height
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - half, y: base))
    path.addLine(to: CGPoint(x: cx, y: top))
    path.addLine(to: CGPoint(x: cx + half, y: base))
    path.closeSubpath()
    context.setFillColor(palette.hillA.withAlphaComponent(0.95).cgColor)
    context.addPath(path)
    context.fillPath()
    // 亮面。
    context.setFillColor(palette.accent.withAlphaComponent(0.35).cgColor)
    let lit = CGMutablePath()
    lit.move(to: CGPoint(x: cx - half, y: base))
    lit.addLine(to: CGPoint(x: cx, y: top))
    lit.addLine(to: CGPoint(x: cx - half * 0.15, y: base))
    lit.closeSubpath()
    context.addPath(lit)
    context.fillPath()
}

private func drawColosseum(_ context: CGContext, rect: CGRect, palette: Palette) {
    let base = rect.height * 0.22
    let width = rect.width * 0.52
    let height = rect.height * 0.22
    let x = rect.midX - width / 2
    context.setFillColor(palette.hillA.cgColor)
    context.fill(CGRect(x: x, y: base, width: width, height: height))
    // 拱门两层。
    context.setFillColor(ink(0.85).cgColor)
    for row in 0..<2 {
        let y = base + height * (0.18 + CGFloat(row) * 0.40)
        var ax = x + width * 0.05
        while ax < x + width - width * 0.06 {
            context.fillEllipse(in: CGRect(x: ax, y: y, width: width * 0.055, height: height * 0.26))
            ax += width * 0.085
        }
    }
}

private func drawDome(_ context: CGContext, rect: CGRect, x: CGFloat, baseY: CGFloat,
                      width: CGFloat, color: NSColor) {
    let base = rect.height * baseY
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: x - width / 2, y: base, width: width, height: rect.height * 0.10))
    context.fillEllipse(in: CGRect(x: x - width * 0.46, y: base + rect.height * 0.08,
                                   width: width * 0.92, height: width * 0.62))
}

private func drawSantorniHouses(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 悬崖。
    let cliff = CGMutablePath()
    cliff.move(to: CGPoint(x: 0, y: 0))
    cliff.addLine(to: CGPoint(x: 0, y: rect.height * 0.36))
    cliff.addLine(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.30))
    cliff.addLine(to: CGPoint(x: rect.width * 0.46, y: rect.height * 0.20))
    cliff.addLine(to: CGPoint(x: rect.width * 0.70, y: rect.height * 0.14))
    cliff.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.10))
    cliff.addLine(to: CGPoint(x: rect.width, y: 0))
    cliff.closeSubpath()
    context.setFillColor(palette.hillA.withAlphaComponent(0.9).cgColor)
    context.addPath(cliff)
    context.fillPath()
    // 白色小屋与蓝顶。
    let houses: [(CGFloat, CGFloat, CGFloat)] = [
        (0.16, 0.32, 0.09), (0.28, 0.34, 0.11), (0.40, 0.29, 0.10),
        (0.52, 0.26, 0.12), (0.64, 0.22, 0.09), (0.76, 0.19, 0.10)
    ]
    for (xRatio, yRatio, sizeRatio) in houses {
        let x = rect.width * xRatio
        let y = rect.height * yRatio
        let size = rect.width * sizeRatio
        context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 0.96).cgColor)
        context.fill(CGRect(x: x, y: y, width: size, height: size * 0.62))
        context.setFillColor(palette.accent.cgColor)
        context.fillEllipse(in: CGRect(x: x + size * 0.16, y: y + size * 0.42,
                                       width: size * 0.68, height: size * 0.42))
    }
}

private func drawWindmill(_ context: CGContext, rect: CGRect, palette: Palette,
                          centerX: CGFloat, baseY: CGFloat) {
    let cx = rect.width * centerX
    let base = rect.height * baseY
    let height = rect.height * 0.22
    let width = rect.width * 0.07
    context.setFillColor(ink(0.8).cgColor)
    context.fill(CGRect(x: cx - width / 2, y: base, width: width, height: height))
    let hub = CGPoint(x: cx, y: base + height)
    for index in 0..<4 {
        let angle = CGFloat(index) * .pi / 2 + 0.4
        let end = CGPoint(x: hub.x + cos(angle) * rect.width * 0.09,
                          y: hub.y + sin(angle) * rect.width * 0.09)
        context.setStrokeColor(ink(0.8).cgColor)
        context.setLineWidth(rect.width * 0.008)
        context.move(to: hub)
        context.addLine(to: end)
        context.strokePath()
        context.fillEllipse(in: CGRect(x: end.x - rect.width * 0.008, y: end.y - rect.width * 0.008,
                                       width: rect.width * 0.016, height: rect.width * 0.016))
    }
    // 郁金香色块。
    for index in 0..<12 {
        let x = rect.width * (0.04 + CGFloat(index) * 0.08)
        context.setFillColor((index % 2 == 0 ? palette.accent : palette.glow).withAlphaComponent(0.5).cgColor)
        context.fillEllipse(in: CGRect(x: x, y: rect.height * 0.16,
                                       width: rect.width * 0.03, height: rect.height * 0.03))
    }
}

private func drawStatue(_ context: CGContext, rect: CGRect, palette: Palette) {
    let base = rect.height * 0.24
    let cx = rect.width * 0.36
    let pedestal = rect.height * 0.12
    context.setFillColor(ink(0.8).cgColor)
    context.fill(CGRect(x: cx - rect.width * 0.06, y: base,
                        width: rect.width * 0.12, height: pedestal))
    let bodyBase = base + pedestal
    let bodyHeight = rect.height * 0.30
    context.fill(CGRect(x: cx - rect.width * 0.035, y: bodyBase,
                        width: rect.width * 0.07, height: bodyHeight))
    // 头 + 火炬。
    context.fillEllipse(in: CGRect(x: cx - rect.width * 0.022, y: bodyBase + bodyHeight,
                                   width: rect.width * 0.044, height: rect.height * 0.06))
    context.setStrokeColor(ink(0.8).cgColor)
    context.setLineWidth(rect.width * 0.010)
    context.move(to: CGPoint(x: cx + rect.width * 0.030, y: bodyBase + bodyHeight * 0.82))
    context.addLine(to: CGPoint(x: cx + rect.width * 0.055, y: bodyBase + bodyHeight * 1.22))
    context.strokePath()
    context.setFillColor(palette.accent.withAlphaComponent(0.9).cgColor)
    context.fillEllipse(in: CGRect(x: cx + rect.width * 0.042, y: bodyBase + bodyHeight * 1.24,
                                   width: rect.width * 0.026, height: rect.height * 0.035))
    // 冠冕尖刺。
    for index in 0..<5 {
        let angle = CGFloat(index) * .pi / 4 + .pi / 8
        context.move(to: CGPoint(x: cx, y: bodyBase + bodyHeight + rect.height * 0.03))
        context.addLine(to: CGPoint(x: cx + cos(angle) * rect.width * 0.035,
                                    y: bodyBase + bodyHeight + rect.height * 0.03 + sin(angle) * rect.height * 0.035))
        context.strokePath()
    }
}

private func drawOperaHouse(_ context: CGContext, rect: CGRect, palette: Palette) {
    let base = rect.height * 0.24
    let color = NSColor(calibratedWhite: 0.96, alpha: 0.94)
    for index in 0..<3 {
        let x = rect.width * (0.30 + CGFloat(index) * 0.14)
        let height = rect.height * (0.16 - CGFloat(index) * 0.025)
        let shell = CGMutablePath()
        shell.move(to: CGPoint(x: x - rect.width * 0.10, y: base))
        shell.addQuadCurve(to: CGPoint(x: x + rect.width * 0.02, y: base + height),
                           control: CGPoint(x: x - rect.width * 0.09, y: base + height * 0.9))
        shell.addQuadCurve(to: CGPoint(x: x + rect.width * 0.10, y: base),
                           control: CGPoint(x: x + rect.width * 0.07, y: base + height * 0.6))
        shell.closeSubpath()
        context.setFillColor(color.cgColor)
        context.addPath(shell)
        context.fillPath()
    }
    context.setFillColor(ink(0.6).cgColor)
    context.fill(CGRect(x: rect.width * 0.28, y: base - rect.height * 0.04,
                        width: rect.width * 0.44, height: rect.height * 0.04))
}

private func drawSuspension(_ context: CGContext, rect: CGRect, palette: Palette,
                            color: NSColor, towers: [CGFloat]) {
    let deckY = rect.height * 0.30
    let towerTop = rect.height * 0.52
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(rect.width * 0.010)
    context.move(to: CGPoint(x: 0, y: deckY))
    context.addLine(to: CGPoint(x: rect.width, y: deckY))
    context.strokePath()
    for ratio in towers {
        let x = rect.width * ratio
        context.setLineWidth(rect.width * 0.016)
        context.move(to: CGPoint(x: x, y: rect.height * 0.18))
        context.addLine(to: CGPoint(x: x, y: towerTop))
        context.strokePath()
        // 主缆。
        context.setLineWidth(rect.width * 0.004)
        let cable = CGMutablePath()
        cable.move(to: CGPoint(x: x, y: towerTop))
        cable.addQuadCurve(to: CGPoint(x: rect.width * (ratio + 0.25), y: deckY),
                           control: CGPoint(x: rect.width * (ratio + 0.10), y: deckY + rect.height * 0.02))
        context.addPath(cable)
        context.strokePath()
    }
}

private func drawSkyline(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    drawCity(context, rect: CGRect(x: 0, y: rect.height * 0.18,
                                   width: rect.width, height: rect.height * 0.70),
             palette: palette, seed: seed)
}

private func drawPalm(_ context: CGContext, rect: CGRect, x: CGFloat, baseY: CGFloat,
                      height: CGFloat, color: NSColor) {
    let base = rect.height * baseY
    let cx = rect.width * x
    let top = base + rect.height * height
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(rect.width * 0.012)
    context.move(to: CGPoint(x: cx, y: base))
    context.addQuadCurve(to: CGPoint(x: cx + rect.width * 0.02, y: top),
                         control: CGPoint(x: cx - rect.width * 0.02, y: base + rect.height * height * 0.5))
    context.strokePath()
    for index in 0..<7 {
        let angle = CGFloat(index) * .pi * 2 / 7
        let tip = CGPoint(x: cx + cos(angle) * rect.width * 0.09,
                          y: top + sin(angle) * rect.height * 0.05)
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: cx + rect.width * 0.02, y: top))
        leaf.addQuadCurve(to: tip, control: CGPoint(x: cx + cos(angle) * rect.width * 0.06,
                                                    y: top + sin(angle) * rect.height * 0.06))
        leaf.addQuadCurve(to: CGPoint(x: cx + rect.width * 0.02, y: top),
                          control: CGPoint(x: cx + cos(angle + 0.5) * rect.width * 0.02,
                                           y: top + sin(angle + 0.5) * rect.height * 0.02))
        leaf.closeSubpath()
        context.setFillColor(color.cgColor)
        context.addPath(leaf)
        context.fillPath()
    }
}

private func drawCherryTrees(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    var rng = SeededRandom(seed: seed)
    for index in 0..<9 {
        let x = rect.width * (0.04 + CGFloat(index) * 0.115)
        let trunkTop = rect.height * (0.30 + CGFloat(rng.next()) * 0.08)
        context.setStrokeColor(ink(0.55).cgColor)
        context.setLineWidth(rect.width * 0.008)
        context.move(to: CGPoint(x: x, y: rect.height * 0.18))
        context.addLine(to: CGPoint(x: x + rect.width * 0.01, y: trunkTop))
        context.strokePath()
        context.setFillColor(palette.accent.withAlphaComponent(0.72).cgColor)
        for _ in 0..<4 {
            let radius = rect.width * (0.035 + CGFloat(rng.next()) * 0.03)
            let cx = x + CGFloat(rng.next()) * rect.width * 0.08 - rect.width * 0.02
            let cy = trunkTop + CGFloat(rng.next()) * rect.height * 0.05
            context.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius * 0.7,
                                           width: radius * 2, height: radius * 1.5))
        }
    }
}

private func drawBoat(_ context: CGContext, rect: CGRect, palette: Palette,
                      x: CGFloat, baseY: CGFloat, width: CGFloat) {
    let base = rect.height * baseY
    let cx = rect.width * x
    let half = rect.width * width * 0.5
    let hull = CGMutablePath()
    hull.move(to: CGPoint(x: cx - half, y: base))
    hull.addQuadCurve(to: CGPoint(x: cx + half, y: base),
                      control: CGPoint(x: cx, y: base - rect.height * 0.02))
    hull.addLine(to: CGPoint(x: cx + half * 0.82, y: base + rect.height * 0.03))
    hull.addLine(to: CGPoint(x: cx - half * 0.82, y: base + rect.height * 0.03))
    hull.closeSubpath()
    context.setFillColor(ink(0.85).cgColor)
    context.addPath(hull)
    context.fillPath()
    // 桅杆与帆。
    context.setStrokeColor(ink(0.85).cgColor)
    context.setLineWidth(rect.width * 0.004)
    context.move(to: CGPoint(x: cx, y: base))
    context.addLine(to: CGPoint(x: cx, y: base + rect.height * 0.14))
    context.strokePath()
    let sail = CGMutablePath()
    sail.move(to: CGPoint(x: cx, y: base + rect.height * 0.135))
    sail.addLine(to: CGPoint(x: cx + half * 0.7, y: base + rect.height * 0.05))
    sail.addLine(to: CGPoint(x: cx, y: base + rect.height * 0.05))
    sail.closeSubpath()
    context.setFillColor(palette.glow.withAlphaComponent(0.55).cgColor)
    context.addPath(sail)
    context.fillPath()
}

private func drawKarst(_ context: CGContext, rect: CGRect, palette: Palette) {
    for (index, item) in [(CGFloat(0.18), CGFloat(0.30)), (0.36, 0.38), (0.55, 0.32),
                          (0.74, 0.40), (0.90, 0.28)].enumerated() {
        let (x, height) = item
        let width = rect.width * (0.14 + CGFloat(index % 2) * 0.04)
        let base = rect.height * 0.20
        let top = base + rect.height * height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.width * x - width / 2, y: base))
        path.addQuadCurve(to: CGPoint(x: rect.width * x, y: top),
                          control: CGPoint(x: rect.width * x - width * 0.45, y: base + (top - base) * 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.width * x + width / 2, y: base),
                          control: CGPoint(x: rect.width * x + width * 0.45, y: base + (top - base) * 0.7))
        path.closeSubpath()
        context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
        context.addPath(path)
        context.fillPath()
    }
    drawSea(context, rect: rect, palette: palette, horizon: 0.20)
}

private func drawGeyser(_ context: CGContext, rect: CGRect, palette: Palette) {
    let center = CGPoint(x: rect.width * 0.55, y: rect.height * 0.30)
    for (index, ratio) in [1.0, 0.72, 0.48, 0.26].enumerated() {
        let radius = rect.width * 0.30 * CGFloat(ratio)
        context.setFillColor((index % 2 == 0 ? palette.accent : palette.glow)
            .withAlphaComponent(0.55).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius * 0.34,
                                       width: radius * 2, height: radius * 0.68))
    }
    // 蒸汽。
    for index in 0..<5 {
        let x = rect.width * (0.42 + CGFloat(index) * 0.055)
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor)
        context.fillEllipse(in: CGRect(x: x, y: rect.height * 0.34,
                                       width: rect.width * 0.10, height: rect.height * 0.22))
    }
}

private func drawReef(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawSea(context, rect: rect, palette: palette, horizon: 0.62)
    // 珊瑚。
    for index in 0..<7 {
        let x = rect.width * (0.08 + CGFloat(index) * 0.13)
        let base = rect.height * (0.10 + CGFloat(index % 3) * 0.03)
        let height = rect.height * (0.10 + CGFloat(index % 2) * 0.05)
        let color = index % 2 == 0 ? palette.accent : palette.glow
        context.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(rect.width * 0.008)
        for branch in 0..<3 {
            let angle = -.pi / 2 + CGFloat(branch - 1) * 0.5
            context.move(to: CGPoint(x: x, y: base))
            context.addLine(to: CGPoint(x: x + cos(angle) * rect.width * 0.04,
                                        y: base + height * (0.6 + CGFloat(branch) * 0.2)))
            context.strokePath()
        }
    }
    // 浅滩白沙。
    context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 0.30).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.08))
}

private func drawJetty(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawRidge(context, rect: rect, palette: palette, baseY: 0.22, height: 0.26,
              peaks: [0.55, 0.85, 0.45, 0.95, 0.40, 0.70], color: palette.hillA)
    drawSea(context, rect: rect, palette: palette, horizon: 0.22)
    context.setFillColor(ink(0.8).cgColor)
    context.fill(CGRect(x: rect.width * 0.10, y: rect.height * 0.20,
                        width: rect.width * 0.48, height: rect.height * 0.016))
    for index in 0..<6 {
        let x = rect.width * (0.12 + CGFloat(index) * 0.08)
        context.fill(CGRect(x: x, y: rect.height * 0.10, width: rect.width * 0.008,
                            height: rect.height * 0.10))
    }
}

private func drawBillboards(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    drawCity(context, rect: CGRect(x: 0, y: rect.height * 0.16,
                                   width: rect.width, height: rect.height * 0.74),
             palette: palette, seed: seed)
    var rng = SeededRandom(seed: seed &+ 3)
    for row in 0..<4 {
        for column in 0..<6 {
            let width = rect.width * 0.11
            let height = rect.height * 0.10
            let x = rect.width * 0.04 + CGFloat(column) * width * 1.12
            let y = rect.height * (0.34 + CGFloat(row) * 0.13)
            let color = [palette.accent, palette.glow, palette.hillA][rng.int(0...2)]
            context.setFillColor(color.withAlphaComponent(0.82).cgColor)
            context.fill(CGRect(x: x, y: y, width: width, height: height))
        }
    }
}

private func drawLouvre(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 卢浮宫长条宫殿 + 中央玻璃金字塔。
    context.setFillColor(palette.hillA.withAlphaComponent(0.9).cgColor)
    context.fill(CGRect(x: 0, y: rect.height * 0.22, width: rect.width * 0.30, height: rect.height * 0.13))
    context.fill(CGRect(x: rect.width * 0.70, y: rect.height * 0.22,
                        width: rect.width * 0.30, height: rect.height * 0.13))
    drawPyramid(context, rect: rect, palette: palette, centerX: 0.5, baseY: 0.22,
                width: 0.22, height: 0.20)
}

private func drawCanal(_ context: CGContext, rect: CGRect, palette: Palette, snow: Bool) {
    let houseColor = snow ? NSColor(calibratedWhite: 0.92, alpha: 0.9) : palette.hillA.withAlphaComponent(0.9)
    for index in 0..<7 {
        let x = rect.width * (0.02 + CGFloat(index) * 0.14)
        let height = rect.height * (0.14 + CGFloat(index % 3) * 0.03)
        context.setFillColor(houseColor.cgColor)
        context.fill(CGRect(x: x, y: rect.height * 0.22, width: rect.width * 0.115, height: height))
        context.setFillColor(ink(0.55).cgColor)
        for window in 0..<2 {
            context.fill(CGRect(x: x + rect.width * 0.02 + CGFloat(window) * rect.width * 0.05,
                                y: rect.height * 0.26, width: rect.width * 0.022,
                                height: rect.height * 0.03))
        }
    }
    context.setFillColor(palette.hillB.withAlphaComponent(snow ? 0.35 : 0.65).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.22))
    if !snow {
        drawBoat(context, rect: rect, palette: palette, x: 0.52, baseY: 0.12, width: 0.22)
    }
}

// MARK: - 日常生活与国内景点

private func drawWindow(_ context: CGContext, rect: CGRect) {
    context.setFillColor(NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.84, alpha: 0.55).cgColor)
    context.fill(rect)
    context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
    context.setLineWidth(max(2, rect.width * 0.012))
    context.stroke(rect)
    context.move(to: CGPoint(x: rect.midX, y: rect.minY))
    context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    context.move(to: CGPoint(x: rect.minX, y: rect.midY))
    context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    context.strokePath()
}

/// 室内：客厅 / 年夜饭 / 生日。家具用色块，重点是暖光和一家人。
private func drawHomeInterior(_ context: CGContext, rect: CGRect, palette: Palette, cake: Bool) {
    let floorY = rect.height * 0.34
    context.setFillColor(palette.hillA.withAlphaComponent(0.55).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: floorY))
    drawWindow(context, rect: CGRect(x: rect.width * 0.56, y: rect.height * 0.40,
                                     width: rect.width * 0.30, height: rect.height * 0.36))
    // 窗帘。
    context.setFillColor(palette.accent.withAlphaComponent(0.35).cgColor)
    context.fill(CGRect(x: rect.width * 0.53, y: rect.height * 0.36,
                        width: rect.width * 0.05, height: rect.height * 0.42))
    context.fill(CGRect(x: rect.width * 0.84, y: rect.height * 0.36,
                        width: rect.width * 0.05, height: rect.height * 0.42))
    // 吊灯。
    context.setStrokeColor(ink(0.5).cgColor)
    context.setLineWidth(max(2, rect.width * 0.003))
    context.move(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.86))
    context.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.74))
    context.strokePath()
    drawGlow(context, center: CGPoint(x: rect.width * 0.30, y: rect.height * 0.72),
             radius: rect.width * 0.16, color: palette.glow)
    // 沙发与茶几。
    context.setFillColor(palette.hillB.withAlphaComponent(0.85).cgColor)
    context.fill(CGRect(x: rect.width * 0.04, y: floorY * 0.45,
                        width: rect.width * 0.26, height: floorY * 0.42))
    context.fill(CGRect(x: rect.width * 0.04, y: floorY * 0.80,
                        width: rect.width * 0.26, height: floorY * 0.18))
    context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
    context.fill(CGRect(x: rect.width * 0.36, y: floorY * 0.30,
                        width: rect.width * 0.24, height: floorY * 0.10))
    if cake {
        // 蛋糕与蜡烛。
        context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 0.95).cgColor)
        context.fill(CGRect(x: rect.width * 0.44, y: floorY * 0.42,
                            width: rect.width * 0.07, height: floorY * 0.13))
        context.setFillColor(palette.accent.cgColor)
        for index in 0..<3 {
            let x = rect.width * (0.455 + CGFloat(index) * 0.018)
            context.fill(CGRect(x: x, y: floorY * 0.55, width: rect.width * 0.005,
                                height: floorY * 0.06))
            context.setFillColor(palette.glow.withAlphaComponent(0.95).cgColor)
            context.fillEllipse(in: CGRect(x: x - rect.width * 0.004, y: floorY * 0.60,
                                           width: rect.width * 0.013, height: rect.width * 0.013))
            context.setFillColor(palette.accent.cgColor)
        }
    }
}

private func drawSchoolGate(_ context: CGContext, rect: CGRect, palette: Palette) {
    let base = rect.height * 0.20
    // 教学楼。
    context.setFillColor(palette.hillA.withAlphaComponent(0.6).cgColor)
    context.fill(CGRect(x: rect.width * 0.06, y: base, width: rect.width * 0.88, height: rect.height * 0.26))
    context.setFillColor(palette.glow.withAlphaComponent(0.35).cgColor)
    for row in 0..<2 {
        for column in 0..<6 {
            context.fill(CGRect(x: rect.width * (0.12 + CGFloat(column) * 0.13),
                                y: base + rect.height * (0.05 + CGFloat(row) * 0.10),
                                width: rect.width * 0.055, height: rect.height * 0.05))
        }
    }
    // 校门与跑道。
    context.setFillColor(ink(0.75).cgColor)
    context.fill(CGRect(x: rect.width * 0.40, y: base, width: rect.width * 0.06, height: rect.height * 0.10))
    context.fill(CGRect(x: rect.width * 0.56, y: base, width: rect.width * 0.06, height: rect.height * 0.10))
    context.fill(CGRect(x: rect.width * 0.40, y: base + rect.height * 0.10,
                        width: rect.width * 0.22, height: rect.height * 0.018))
    // 旗杆。
    context.setStrokeColor(ink(0.6).cgColor)
    context.setLineWidth(max(2, rect.width * 0.004))
    context.move(to: CGPoint(x: rect.width * 0.90, y: base))
    context.addLine(to: CGPoint(x: rect.width * 0.90, y: base + rect.height * 0.30))
    context.strokePath()
    context.setFillColor(NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.18, alpha: 0.9).cgColor)
    context.fill(CGRect(x: rect.width * 0.905, y: base + rect.height * 0.24,
                        width: rect.width * 0.05, height: rect.height * 0.05))
}

private func drawPark(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.30))
    var rng = SeededRandom(seed: seed &+ 9)
    for index in 0..<5 {
        let x = rect.width * (0.08 + CGFloat(index) * 0.21)
        let trunkTop = rect.height * (0.34 + CGFloat(rng.next()) * 0.06)
        context.setStrokeColor(ink(0.5).cgColor)
        context.setLineWidth(max(3, rect.width * 0.006))
        context.move(to: CGPoint(x: x, y: rect.height * 0.28))
        context.addLine(to: CGPoint(x: x, y: trunkTop))
        context.strokePath()
        context.setFillColor(palette.hillB.withAlphaComponent(0.85).cgColor)
        context.fillEllipse(in: CGRect(x: x - rect.width * 0.07, y: trunkTop - rect.height * 0.04,
                                       width: rect.width * 0.14, height: rect.height * 0.12))
        context.setFillColor(palette.hillA.withAlphaComponent(0.7).cgColor)
        context.fillEllipse(in: CGRect(x: x - rect.width * 0.05, y: trunkTop + rect.height * 0.02,
                                       width: rect.width * 0.10, height: rect.height * 0.08))
    }
    // 小路与长椅。
    context.setFillColor(palette.bottom.withAlphaComponent(0.55).cgColor)
    context.fill(CGRect(x: rect.width * 0.30, y: 0, width: rect.width * 0.16, height: rect.height * 0.30))
    context.setFillColor(ink(0.55).cgColor)
    context.fill(CGRect(x: rect.width * 0.62, y: rect.height * 0.20,
                        width: rect.width * 0.14, height: rect.height * 0.015))
    context.fill(CGRect(x: rect.width * 0.63, y: rect.height * 0.22,
                        width: rect.width * 0.012, height: rect.height * 0.045))
    context.fill(CGRect(x: rect.width * 0.74, y: rect.height * 0.22,
                        width: rect.width * 0.012, height: rect.height * 0.045))
}

private func drawSupermarket(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    var rng = SeededRandom(seed: seed &+ 13)
    for row in 0..<3 {
        let y = rect.height * (0.22 + CGFloat(row) * 0.17)
        context.setFillColor(ink(0.35).cgColor)
        context.fill(CGRect(x: rect.width * 0.05, y: y, width: rect.width * 0.90, height: rect.height * 0.012))
        for index in 0..<14 {
            let x = rect.width * (0.07 + CGFloat(index) * 0.063)
            let height = rect.height * (0.045 + CGFloat(rng.next()) * 0.03)
            let colors: [NSColor] = [palette.accent, palette.glow, palette.hillA, palette.top]
            context.setFillColor(colors[rng.int(0...3)].withAlphaComponent(0.8).cgColor)
            context.fill(CGRect(x: x, y: y + rect.height * 0.012, width: rect.width * 0.038, height: height))
        }
    }
    // 购物车。
    context.setStrokeColor(ink(0.6).cgColor)
    context.setLineWidth(max(3, rect.width * 0.005))
    let cart = CGRect(x: rect.width * 0.08, y: rect.height * 0.06, width: rect.width * 0.16, height: rect.height * 0.10)
    context.stroke(cart)
    context.move(to: CGPoint(x: cart.minX + rect.width * 0.02, y: cart.maxY))
    context.addLine(to: CGPoint(x: cart.minX - rect.width * 0.02, y: cart.maxY + rect.height * 0.03))
    context.strokePath()
    for x in [cart.minX + rect.width * 0.03, cart.maxX - rect.width * 0.03] {
        context.fillEllipse(in: CGRect(x: x - rect.width * 0.008, y: cart.minY - rect.height * 0.02,
                                       width: rect.width * 0.016, height: rect.width * 0.016))
    }
}

private func drawOffice(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawWindow(context, rect: CGRect(x: rect.width * 0.06, y: rect.height * 0.44,
                                     width: rect.width * 0.36, height: rect.height * 0.40))
    // 窗外天际线。
    context.setFillColor(palette.hillB.withAlphaComponent(0.45).cgColor)
    context.fill(CGRect(x: rect.width * 0.06, y: rect.height * 0.44,
                        width: rect.width * 0.36, height: rect.height * 0.14))
    // 办公桌与显示器。
    context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
    context.fill(CGRect(x: rect.width * 0.46, y: rect.height * 0.34,
                        width: rect.width * 0.48, height: rect.height * 0.03))
    context.setFillColor(ink(0.75).cgColor)
    context.fill(CGRect(x: rect.width * 0.56, y: rect.height * 0.37,
                        width: rect.width * 0.20, height: rect.height * 0.16))
    context.setFillColor(palette.glow.withAlphaComponent(0.55).cgColor)
    context.fill(CGRect(x: rect.width * 0.57, y: rect.height * 0.385,
                        width: rect.width * 0.18, height: rect.height * 0.13))
    // 椅子与绿植。
    context.setFillColor(ink(0.65).cgColor)
    context.fill(CGRect(x: rect.width * 0.72, y: rect.height * 0.18,
                        width: rect.width * 0.10, height: rect.height * 0.10))
    context.setFillColor(palette.hillA.cgColor)
    context.fillEllipse(in: CGRect(x: rect.width * 0.12, y: rect.height * 0.30,
                                   width: rect.width * 0.08, height: rect.height * 0.08))
}

private func drawClassroom(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 白板与板书。
    context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 0.92).cgColor)
    context.fill(CGRect(x: rect.width * 0.18, y: rect.height * 0.46,
                        width: rect.width * 0.64, height: rect.height * 0.26))
    context.setStrokeColor(palette.hillA.withAlphaComponent(0.65).cgColor)
    context.setLineWidth(max(2, rect.width * 0.004))
    for index in 0..<5 {
        let y = rect.height * (0.64 - CGFloat(index) * 0.03)
        context.move(to: CGPoint(x: rect.width * 0.22, y: y))
        context.addLine(to: CGPoint(x: rect.width * (0.40 + CGFloat(index % 3) * 0.10), y: y))
        context.strokePath()
    }
    // 课桌。
    for row in 0..<2 {
        for column in 0..<4 {
            let x = rect.width * (0.10 + CGFloat(column) * 0.21)
            let y = rect.height * (0.10 + CGFloat(row) * 0.13)
            // 坐着的孩子：头 + 肩。
            context.setFillColor(ink(0.70).cgColor)
            let headRadius = rect.height * 0.018
            context.fillEllipse(in: CGRect(x: x + rect.width * 0.055, y: y + rect.height * 0.035,
                                           width: headRadius * 2, height: headRadius * 2))
            context.fill(CGRect(x: x + rect.width * 0.035, y: y + rect.height * 0.012,
                                width: rect.width * 0.055, height: rect.height * 0.028))
            context.setFillColor(palette.hillA.withAlphaComponent(0.75).cgColor)
            context.fill(CGRect(x: x, y: y, width: rect.width * 0.14, height: rect.height * 0.02))
            context.setFillColor(ink(0.6).cgColor)
            context.fill(CGRect(x: x + rect.width * 0.055, y: y - rect.height * 0.10,
                                width: rect.width * 0.008, height: rect.height * 0.10))
        }
    }
    // 讲台旁的老师。
    context.setFillColor(ink(0.75).cgColor)
    context.fill(CGRect(x: rect.width * 0.10, y: rect.height * 0.12,
                        width: rect.width * 0.045, height: rect.height * 0.16))
    context.fillEllipse(in: CGRect(x: rect.width * 0.10, y: rect.height * 0.29,
                                   width: rect.width * 0.045, height: rect.height * 0.045))
}

private func drawPianoRoom(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 三角钢琴剪影。
    let body = CGMutablePath()
    body.move(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.20))
    body.addLine(to: CGPoint(x: rect.width * 0.66, y: rect.height * 0.20))
    body.addQuadCurve(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.40),
                      control: CGPoint(x: rect.width * 0.84, y: rect.height * 0.22))
    body.addLine(to: CGPoint(x: rect.width * 0.56, y: rect.height * 0.42))
    body.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.30))
    body.closeSubpath()
    context.setFillColor(ink(0.85).cgColor)
    context.addPath(body)
    context.fillPath()
    // 琴键。
    context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 0.95).cgColor)
    context.fill(CGRect(x: rect.width * 0.30, y: rect.height * 0.20,
                        width: rect.width * 0.36, height: rect.height * 0.03))
    // 谱架。
    context.fill(CGRect(x: rect.width * 0.52, y: rect.height * 0.42,
                        width: rect.width * 0.10, height: rect.height * 0.06))
    // 琴凳。
    context.setFillColor(palette.hillA.withAlphaComponent(0.8).cgColor)
    context.fill(CGRect(x: rect.width * 0.46, y: rect.height * 0.12,
                        width: rect.width * 0.14, height: rect.height * 0.04))
}

private func drawSportsDay(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 跑道。
    context.setFillColor(palette.accent.withAlphaComponent(0.55).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.30))
    context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
    context.setLineWidth(max(2, rect.width * 0.003))
    for index in 0..<4 {
        let y = rect.height * (0.05 + CGFloat(index) * 0.06)
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: rect.width, y: y))
        context.strokePath()
    }
    // 看台。
    context.setFillColor(palette.hillA.withAlphaComponent(0.8).cgColor)
    context.fill(CGRect(x: 0, y: rect.height * 0.30, width: rect.width, height: rect.height * 0.10))
    // 跑步的孩子。
    for index in 0..<4 {
        let x = rect.width * (0.22 + CGFloat(index) * 0.16)
        let height = rect.height * 0.15
        drawPerson(context, baseX: x, baseY: rect.height * 0.12, height: height,
                   style: index % 2 == 0 ? .elder : .younger, color: ink(0.75), lean: 1)
    }
}

private func drawSafari(_ context: CGContext, rect: CGRect, palette: Palette) {
    context.setFillColor(palette.hillA.withAlphaComponent(0.75).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.34))
    // 金合欢树。
    let treeX = rect.width * 0.78
    context.setStrokeColor(ink(0.75).cgColor)
    context.setLineWidth(max(4, rect.width * 0.010))
    context.move(to: CGPoint(x: treeX, y: rect.height * 0.30))
    context.addLine(to: CGPoint(x: treeX, y: rect.height * 0.48))
    context.strokePath()
    context.setFillColor(palette.hillB.withAlphaComponent(0.9).cgColor)
    context.fillEllipse(in: CGRect(x: treeX - rect.width * 0.14, y: rect.height * 0.46,
                                   width: rect.width * 0.28, height: rect.height * 0.09))
    // 长颈鹿。
    let giraffeX = rect.width * 0.24
    context.setFillColor(palette.accent.withAlphaComponent(0.9).cgColor)
    context.fill(CGRect(x: giraffeX, y: rect.height * 0.20, width: rect.width * 0.06, height: rect.height * 0.16))
    context.fill(CGRect(x: giraffeX + rect.width * 0.02, y: rect.height * 0.34,
                        width: rect.width * 0.025, height: rect.height * 0.16))
    context.fillEllipse(in: CGRect(x: giraffeX + rect.width * 0.005, y: rect.height * 0.48,
                                   width: rect.width * 0.06, height: rect.height * 0.05))
    for index in 0..<4 {
        let x = giraffeX + rect.width * (0.01 + CGFloat(index) * 0.013)
        context.fill(CGRect(x: x, y: rect.height * 0.14, width: rect.width * 0.008,
                            height: rect.height * 0.07))
    }
    // 大象。
    let elephantX = rect.width * 0.52
    context.setFillColor(NSColor(calibratedWhite: 0.45, alpha: 0.9).cgColor)
    context.fillEllipse(in: CGRect(x: elephantX, y: rect.height * 0.18,
                                   width: rect.width * 0.18, height: rect.height * 0.14))
    context.fillEllipse(in: CGRect(x: elephantX + rect.width * 0.15, y: rect.height * 0.22,
                                   width: rect.width * 0.07, height: rect.height * 0.10))
}

private func drawWaterPark(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawSea(context, rect: rect, palette: palette, horizon: 0.22)
    // 滑水道：三条彩色曲线。
    let colors: [NSColor] = [palette.accent, palette.glow, NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.30, alpha: 0.9)]
    for (index, color) in colors.enumerated() {
        let startX = rect.width * (0.52 + CGFloat(index) * 0.10)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: rect.height * 0.72))
        path.addQuadCurve(to: CGPoint(x: startX + rect.width * 0.10, y: rect.height * 0.22),
                          control: CGPoint(x: startX + rect.width * 0.16, y: rect.height * 0.50))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(6, rect.width * 0.012))
        context.addPath(path)
        context.strokePath()
    }
    // 支柱与遮阳伞。
    context.setStrokeColor(ink(0.5).cgColor)
    context.setLineWidth(max(4, rect.width * 0.006))
    context.move(to: CGPoint(x: rect.width * 0.50, y: rect.height * 0.22))
    context.addLine(to: CGPoint(x: rect.width * 0.50, y: rect.height * 0.74))
    context.strokePath()
    context.setFillColor(palette.accent.withAlphaComponent(0.8).cgColor)
    context.fillEllipse(in: CGRect(x: rect.width * 0.06, y: rect.height * 0.26,
                                   width: rect.width * 0.16, height: rect.height * 0.05))
}

private func drawWedding(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 花门。
    context.setStrokeColor(ink(0.55).cgColor)
    context.setLineWidth(max(6, rect.width * 0.010))
    context.move(to: CGPoint(x: rect.width * 0.26, y: rect.height * 0.18))
    context.addLine(to: CGPoint(x: rect.width * 0.26, y: rect.height * 0.52))
    context.addQuadCurve(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.52),
                         control: CGPoint(x: rect.width * 0.50, y: rect.height * 0.70))
    context.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.18))
    context.strokePath()
    // 花朵。
    for index in 0..<12 {
        let ratio = CGFloat(index) / 12
        let x = rect.width * (0.26 + ratio * 0.48)
        let y = rect.height * (0.52 + sin(ratio * .pi) * 0.14)
        context.setFillColor(palette.accent.withAlphaComponent(0.85).cgColor)
        context.fillEllipse(in: CGRect(x: x - rect.width * 0.012, y: y - rect.width * 0.012,
                                       width: rect.width * 0.024, height: rect.width * 0.024))
    }
    // 红毯与宾客椅。
    context.setFillColor(NSColor(calibratedRed: 0.70, green: 0.16, blue: 0.16, alpha: 0.85).cgColor)
    context.fill(CGRect(x: rect.width * 0.42, y: 0, width: rect.width * 0.16, height: rect.height * 0.30))
    // 新人站在花门下。
    drawPerson(context, baseX: rect.width * 0.47, baseY: rect.height * 0.10,
               height: rect.height * 0.18, style: .mother,
               color: NSColor(calibratedWhite: 0.98, alpha: 0.95))
    drawPerson(context, baseX: rect.width * 0.53, baseY: rect.height * 0.10,
               height: rect.height * 0.19, style: .father, color: ink(0.8))
    for row in 0..<2 {
        for column in 0..<4 {
            let x = rect.width * (0.10 + CGFloat(column) * 0.10 + CGFloat(row) * 0.02)
            let y = rect.height * (0.06 + CGFloat(row) * 0.10)
            context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 0.80).cgColor)
            context.fill(CGRect(x: x, y: y, width: rect.width * 0.05, height: rect.height * 0.02))
            context.fill(CGRect(x: x, y: y, width: rect.width * 0.008, height: rect.height * 0.06))
        }
    }
}

private func drawStudy(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawWindow(context, rect: CGRect(x: rect.width * 0.58, y: rect.height * 0.44,
                                     width: rect.width * 0.30, height: rect.height * 0.36))
    // 书桌、台灯、书本。
    context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
    context.fill(CGRect(x: rect.width * 0.10, y: rect.height * 0.30,
                        width: rect.width * 0.54, height: rect.height * 0.03))
    drawGlow(context, center: CGPoint(x: rect.width * 0.20, y: rect.height * 0.46),
             radius: rect.width * 0.14, color: palette.glow)
    context.setStrokeColor(ink(0.6).cgColor)
    context.setLineWidth(max(3, rect.width * 0.005))
    context.move(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.33))
    context.addLine(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.46))
    context.addLine(to: CGPoint(x: rect.width * 0.27, y: rect.height * 0.44))
    context.strokePath()
    for index in 0..<3 {
        context.setFillColor([palette.accent, palette.top, palette.hillB][index]
            .withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: rect.width * (0.34 + CGFloat(index) * 0.02), y: rect.height * 0.33,
                            width: rect.width * 0.09, height: rect.height * 0.015))
    }
}

private func drawJiuzhaigou(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 远山。
    drawRidge(context, rect: rect, palette: palette, baseY: 0.34, height: 0.18,
              peaks: [0.25, 0.55, 0.30, 0.70, 0.35, 0.50],
              color: palette.hillA.withAlphaComponent(0.55))
    // 彩林：树干 + 多层树冠，避免出现「漂浮的气球」。
    for index in 0..<7 {
        let x = rect.width * (0.06 + CGFloat(index) * 0.14)
        let height = rect.height * (0.10 + CGFloat(index % 3) * 0.035)
        let trunkTop = rect.height * 0.28 + height
        context.setStrokeColor(palette.hillB.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(max(3, rect.width * 0.005))
        context.move(to: CGPoint(x: x, y: rect.height * 0.24))
        context.addLine(to: CGPoint(x: x, y: trunkTop))
        context.strokePath()
        let colors: [NSColor] = [palette.accent,
                                 NSColor(calibratedRed: 0.92, green: 0.62, blue: 0.28, alpha: 0.9),
                                 NSColor(calibratedRed: 0.86, green: 0.34, blue: 0.26, alpha: 0.85)]
        for layer in 0..<2 {
            let radius = rect.width * (0.075 - CGFloat(layer) * 0.018)
            let centerY = trunkTop + CGFloat(layer) * height * 0.28
            context.setFillColor(colors[(index + layer) % 3].cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: centerY - radius * 0.75,
                                           width: radius * 2, height: radius * 1.5))
        }
    }
    // 层叠彩池：带弧形边缘的水面。
    for index in 0..<3 {
        let y = rect.height * (0.02 + CGFloat(index) * 0.075)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: y))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: y + rect.height * 0.01),
                          control: CGPoint(x: rect.width * 0.5, y: y + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.width, y: y + rect.height * 0.065))
        path.addQuadCurve(to: CGPoint(x: 0, y: y + rect.height * 0.055),
                          control: CGPoint(x: rect.width * 0.5, y: y + rect.height * 0.10))
        path.closeSubpath()
        context.setFillColor((index % 2 == 0 ? palette.accent : palette.glow)
            .withAlphaComponent(0.45).cgColor)
        context.addPath(path)
        context.fillPath()
    }
    // 小瀑布。
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.35).cgColor)
    for index in 0..<5 {
        let x = rect.width * (0.30 + CGFloat(index) * 0.09)
        context.fill(CGRect(x: x, y: rect.height * 0.18, width: rect.width * 0.012, height: rect.height * 0.08))
    }
}

private func drawPotala(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 山丘。
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: 0, y: 0))
    hill.addLine(to: CGPoint(x: 0, y: rect.height * 0.20))
    hill.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.28))
    hill.addLine(to: CGPoint(x: rect.width * 0.70, y: rect.height * 0.28))
    hill.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.20))
    hill.addLine(to: CGPoint(x: rect.width, y: 0))
    hill.closeSubpath()
    context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
    context.addPath(hill)
    context.fillPath()
    // 白宫与红宫。
    context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 0.95).cgColor)
    context.fill(CGRect(x: rect.width * 0.26, y: rect.height * 0.28,
                        width: rect.width * 0.48, height: rect.height * 0.14))
    context.setFillColor(NSColor(calibratedRed: 0.56, green: 0.14, blue: 0.14, alpha: 0.95).cgColor)
    context.fill(CGRect(x: rect.width * 0.40, y: rect.height * 0.33,
                        width: rect.width * 0.20, height: rect.height * 0.16))
    // 金顶。
    context.setFillColor(palette.glow.cgColor)
    for index in 0..<3 {
        let x = rect.width * (0.42 + CGFloat(index) * 0.06)
        context.fill(CGRect(x: x, y: rect.height * 0.49, width: rect.width * 0.045, height: rect.height * 0.02))
    }
    // 经幡。
    for index in 0..<6 {
        let x = rect.width * (0.06 + CGFloat(index) * 0.05)
        context.setFillColor([palette.accent, palette.glow, NSColor(calibratedRed: 0.30, green: 0.52, blue: 0.86, alpha: 0.85)][index % 3].cgColor)
        context.fill(CGRect(x: x, y: rect.height * 0.30, width: rect.width * 0.02, height: rect.height * 0.05))
    }
}

private func drawZhangjiajie(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 石柱群：上窄下宽、顶部长树，避免像柱状图。
    for (index, item) in [(CGFloat(0.10), CGFloat(0.46)), (0.24, 0.60), (0.40, 0.38),
                          (0.54, 0.66), (0.68, 0.44), (0.82, 0.56)].enumerated() {
        let (x, height) = item
        let width = rect.width * (0.075 + CGFloat(index % 2) * 0.03)
        let bottom = rect.height * 0.10
        let top = bottom + rect.height * height
        let inset = width * 0.16
        let pillar = CGMutablePath()
        pillar.move(to: CGPoint(x: rect.width * x, y: bottom))
        pillar.addLine(to: CGPoint(x: rect.width * x + inset, y: top))
        pillar.addLine(to: CGPoint(x: rect.width * x + width - inset, y: top))
        pillar.addLine(to: CGPoint(x: rect.width * x + width, y: bottom))
        pillar.closeSubpath()
        context.setFillColor(palette.hillA.withAlphaComponent(0.9).cgColor)
        context.addPath(pillar)
        context.fillPath()
        // 右侧暗面。
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: rect.width * x + width * 0.62, y: bottom))
        shade.addLine(to: CGPoint(x: rect.width * x + width - inset, y: top))
        shade.addLine(to: CGPoint(x: rect.width * x + width, y: bottom))
        shade.closeSubpath()
        context.setFillColor(palette.hillB.withAlphaComponent(0.8).cgColor)
        context.addPath(shade)
        context.fillPath()
        // 柱顶植被。
        context.setFillColor(NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.24, alpha: 0.9).cgColor)
        context.fillEllipse(in: CGRect(x: rect.width * x - width * 0.08, y: top - rect.height * 0.012,
                                       width: width * 1.16, height: rect.height * 0.028))
    }
    // 云雾。
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.20).cgColor)
    for index in 0..<4 {
        context.fillEllipse(in: CGRect(x: -rect.width * 0.1,
                                       y: rect.height * (0.20 + CGFloat(index) * 0.08),
                                       width: rect.width * 1.2, height: rect.height * 0.05))
    }
}

private func drawHuangshan(_ context: CGContext, rect: CGRect, palette: Palette) {
    drawRidge(context, rect: rect, palette: palette, baseY: 0.26, height: 0.34,
              peaks: [0.30, 0.75, 0.45, 0.90, 0.35], color: palette.hillA)
    // 云海。
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.35).cgColor)
    context.fill(CGRect(x: 0, y: rect.height * 0.22, width: rect.width, height: rect.height * 0.06))
    // 迎客松。
    let pineX = rect.width * 0.18
    context.setStrokeColor(ink(0.7).cgColor)
    context.setLineWidth(max(4, rect.width * 0.008))
    context.move(to: CGPoint(x: pineX, y: rect.height * 0.28))
    context.addLine(to: CGPoint(x: pineX + rect.width * 0.02, y: rect.height * 0.40))
    context.strokePath()
    context.setFillColor(palette.hillB.withAlphaComponent(0.9).cgColor)
    context.fillEllipse(in: CGRect(x: pineX - rect.width * 0.03, y: rect.height * 0.38,
                                   width: rect.width * 0.14, height: rect.height * 0.05))
}

private func drawFamilyPortrait(_ context: CGContext, rect: CGRect, palette: Palette) {
    // 摄影棚背景与柔光。
    drawGlow(context, center: CGPoint(x: rect.width * 0.5, y: rect.height * 0.55),
             radius: rect.width * 0.45, color: palette.glow)
    context.setFillColor(palette.hillA.withAlphaComponent(0.35).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.18))
}

private func drawCastleNight(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    drawCastle(context, rect: rect, palette: palette)
    // 烟花。
    var rng = SeededRandom(seed: seed &+ 23)
    for burst in 0..<3 {
        let center = CGPoint(x: rect.width * (0.22 + CGFloat(burst) * 0.28),
                             y: rect.height * (0.62 + CGFloat(rng.next()) * 0.20))
        let color: NSColor = [palette.accent, palette.glow,
                              NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.86, alpha: 0.9)][burst]
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(2, rect.width * 0.004))
        for ray in 0..<16 {
            let angle = CGFloat(ray) * .pi * 2 / 16
            let length = rect.width * (0.05 + CGFloat(rng.next()) * 0.05)
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + cos(angle) * length,
                                        y: center.y + sin(angle) * length))
            context.strokePath()
        }
    }
}

private enum PersonStyle {
    case father, mother, elder, younger
}

private enum HairStyle {
    case short, sidePart, long, ponytail, bowl
}

private struct PersonLook {
    let skin: NSColor
    let hair: NSColor
    let shirt: NSColor
    let pants: NSColor
    let shoes: NSColor
    let hairStyle: HairStyle
    let accessory: NSColor?
}

/// 四个固定角色：深蓝衬衫爸爸、珊瑚色妈妈、姜黄姐姐、青绿弟弟。
/// 同一组配色贯穿所有年份，让截图里能认出「这一家人」。
private func look(for style: PersonStyle) -> PersonLook {
    switch style {
    case .father:
        return PersonLook(skin: NSColor(calibratedRed: 0.94, green: 0.78, blue: 0.66, alpha: 1),
                          hair: NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.09, alpha: 1),
                          shirt: NSColor(calibratedRed: 0.20, green: 0.28, blue: 0.44, alpha: 1),
                          pants: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                          shoes: NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.12, alpha: 1),
                          hairStyle: .sidePart, accessory: nil)
    case .mother:
        return PersonLook(skin: NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.72, alpha: 1),
                          hair: NSColor(calibratedRed: 0.16, green: 0.11, blue: 0.10, alpha: 1),
                          shirt: NSColor(calibratedRed: 0.84, green: 0.42, blue: 0.38, alpha: 1),
                          pants: NSColor(calibratedRed: 0.26, green: 0.28, blue: 0.38, alpha: 1),
                          shoes: NSColor(calibratedRed: 0.92, green: 0.90, blue: 0.88, alpha: 1),
                          hairStyle: .long, accessory: nil)
    case .elder:
        return PersonLook(skin: NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.74, alpha: 1),
                          hair: NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.10, alpha: 1),
                          shirt: NSColor(calibratedRed: 0.94, green: 0.74, blue: 0.30, alpha: 1),
                          pants: NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.58, alpha: 1),
                          shoes: NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.32, alpha: 1),
                          hairStyle: .ponytail, accessory: NSColor(calibratedRed: 0.90, green: 0.34, blue: 0.34, alpha: 1))
    case .younger:
        return PersonLook(skin: NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.71, alpha: 1),
                          hair: NSColor(calibratedRed: 0.11, green: 0.09, blue: 0.09, alpha: 1),
                          shirt: NSColor(calibratedRed: 0.24, green: 0.60, blue: 0.60, alpha: 1),
                          pants: NSColor(calibratedRed: 0.34, green: 0.38, blue: 0.44, alpha: 1),
                          shoes: NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.60, alpha: 1),
                          hairStyle: .bowl, accessory: nil)
    }
}

/// 可选的照片级人物素材：把 father / mother / elder / younger 四张透明背景 PNG
/// 放进素材目录后，直接合成真人照片；没有素材时退回程序化绘制的插画人物。
private struct FaceAssets {
    let father: CGImage?
    let mother: CGImage?
    let elder: CGImage?
    let younger: CGImage?

    static func load(from directory: URL?) -> FaceAssets? {
        guard let directory else { return nil }
        func image(_ name: String) -> CGImage? {
            let url = directory.appendingPathComponent("\(name).png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let assets = FaceAssets(father: image("father"), mother: image("mother"),
                                elder: image("elder"), younger: image("younger"))
        // 四张齐全才启用：只换掉部分角色会让画面一半照片一半插画。
        var missing: [String] = []
        if assets.father == nil { missing.append("father.png") }
        if assets.mother == nil { missing.append("mother.png") }
        if assets.elder == nil { missing.append("elder.png") }
        if assets.younger == nil { missing.append("younger.png") }
        guard missing.isEmpty else {
            print("人像素材不完整，缺少 \(missing.joined(separator: "、"))，本次仍用插画人物")
            return nil
        }
        return assets
    }

    func image(for style: PersonStyle) -> CGImage? {
        switch style {
        case .father: return father
        case .mother: return mother
        case .elder: return elder
        case .younger: return younger
        }
    }
}

private var faceAssets: FaceAssets?

/// 家庭成员：肤色、头发、五官与衣服配色都画出来，远看是人物，近看有面孔。
private func drawPerson(_ context: CGContext, baseX: CGFloat, baseY: CGFloat,
                        height: CGFloat, style: PersonStyle, color: NSColor,
                        lean: CGFloat = 0, pose: Int = 0) {
    _ = color
    // 有真人素材时直接贴照片：脚底对齐地面，按身高等比缩放。
    if let photo = faceAssets?.image(for: style) {
        let aspect = CGFloat(photo.width) / CGFloat(photo.height)
        let personHeight = height * 1.06
        let personWidth = personHeight * aspect
        context.draw(photo, in: CGRect(x: baseX - personWidth / 2, y: baseY,
                                       width: personWidth, height: personHeight))
        return
    }
    let person = look(for: style)
    let skinShadow = person.skin.blended(
        withFraction: 0.30,
        of: NSColor(calibratedRed: 0.48, green: 0.26, blue: 0.20, alpha: 1)) ?? person.skin
    let headRadius = height * 0.082
    let bodyWidth = height * 0.185
    let hipY = baseY + height * 0.47
    let shoulderY = baseY + height * 0.795
    let headCenter = CGPoint(x: baseX + lean * height * 0.025,
                             y: baseY + height * 0.885)

    // 腿、裤子与鞋。
    let legWidth = bodyWidth * 0.33
    for side in [CGFloat(-1), CGFloat(1)] {
        let x = baseX + side * bodyWidth * 0.21 - legWidth / 2
        context.setFillColor(person.pants.cgColor)
        context.fill(CGRect(x: x, y: baseY + height * 0.045,
                            width: legWidth, height: height * 0.44))
        context.setFillColor(person.shoes.cgColor)
        context.fillEllipse(in: CGRect(x: x - legWidth * 0.22, y: baseY,
                                       width: legWidth * 1.44, height: height * 0.038))
    }
    // 上衣。
    context.setFillColor(person.shirt.cgColor)
    let body = CGMutablePath()
    body.move(to: CGPoint(x: baseX - bodyWidth * 0.46, y: hipY))
    body.addLine(to: CGPoint(x: baseX - bodyWidth * 0.56, y: shoulderY))
    body.addLine(to: CGPoint(x: baseX + bodyWidth * 0.56, y: shoulderY))
    body.addLine(to: CGPoint(x: baseX + bodyWidth * 0.46, y: hipY))
    body.closeSubpath()
    context.addPath(body)
    context.fillPath()

    // 领口：一小块肤色 V 字，让上衣不是一整块色。
    let collar = CGMutablePath()
    collar.move(to: CGPoint(x: baseX - bodyWidth * 0.14, y: shoulderY + height * 0.01))
    collar.addLine(to: CGPoint(x: baseX, y: shoulderY - height * 0.05))
    collar.addLine(to: CGPoint(x: baseX + bodyWidth * 0.14, y: shoulderY + height * 0.01))
    collar.closeSubpath()
    context.setFillColor(person.skin.cgColor)
    context.addPath(collar)
    context.fillPath()

    // 手臂：一侧可举手挥手；上臂衣服、手掌露肤色。
    for side in [CGFloat(-1), CGFloat(1)] {
        let raised = (pose == 1 && side == 1) || (pose == 2 && side == -1)
        if raised {
            let shoulder = CGPoint(x: baseX + side * bodyWidth * 0.48, y: shoulderY - height * 0.02)
            let hand = CGPoint(x: shoulder.x + side * bodyWidth * 0.30, y: shoulderY + height * 0.24)
            context.saveGState()
            context.setStrokeColor(person.shirt.cgColor)
            context.setLineWidth(bodyWidth * 0.20)
            context.setLineCap(.round)
            context.move(to: shoulder)
            context.addLine(to: hand)
            context.strokePath()
            context.restoreGState()
            context.setFillColor(person.skin.cgColor)
            context.fillEllipse(in: CGRect(x: hand.x - bodyWidth * 0.13, y: hand.y - bodyWidth * 0.13,
                                           width: bodyWidth * 0.26, height: bodyWidth * 0.26))
        } else {
            let armX = baseX + side * bodyWidth * 0.62
            context.setFillColor(person.shirt.cgColor)
            context.fill(CGRect(x: armX - bodyWidth * 0.10, y: baseY + height * 0.50,
                                width: bodyWidth * 0.20, height: height * 0.26))
            context.setFillColor(person.skin.cgColor)
            context.fillEllipse(in: CGRect(x: armX - bodyWidth * 0.11, y: baseY + height * 0.47,
                                           width: bodyWidth * 0.22, height: height * 0.065))
        }
    }

    // 脖子与耳朵：脖子顶部压一层暗调，形成下巴的投影。
    context.setFillColor(person.skin.cgColor)
    context.fill(CGRect(x: baseX - bodyWidth * 0.11, y: shoulderY - height * 0.015,
                        width: bodyWidth * 0.22, height: height * 0.08))
    context.setFillColor(skinShadow.withAlphaComponent(0.35).cgColor)
    context.fillEllipse(in: CGRect(x: baseX - bodyWidth * 0.12, y: shoulderY + height * 0.032,
                                   width: bodyWidth * 0.24, height: height * 0.030))
    for side in [CGFloat(-1), CGFloat(1)] {
        context.setFillColor(person.skin.cgColor)
        context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 0.92,
                                       y: headCenter.y - headRadius * 0.16,
                                       width: headRadius * 0.30, height: headRadius * 0.42))
        context.setFillColor(skinShadow.withAlphaComponent(0.25).cgColor)
        context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 0.96,
                                       y: headCenter.y - headRadius * 0.10,
                                       width: headRadius * 0.18, height: headRadius * 0.26))
    }

    // 长发先画在头后面：垂到肩膀，不遮住下巴。
    if person.hairStyle == .long {
        context.setFillColor(person.hair.cgColor)
        context.fillEllipse(in: CGRect(x: headCenter.x - headRadius * 1.28,
                                       y: headCenter.y - headRadius * 1.85,
                                       width: headRadius * 2.56, height: headRadius * 2.75))
        for side in [CGFloat(-1), CGFloat(1)] {
            context.fill(CGRect(x: headCenter.x + side * headRadius * 0.86 - headRadius * 0.30,
                                y: headCenter.y - headRadius * 1.30,
                                width: headRadius * 0.44, height: headRadius * 2.35))
        }
    }

    // 头：左上方受光的渐变肤色，避免一张脸是一块平色。
    let headRect = CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                          width: headRadius * 2, height: headRadius * 2)
    context.saveGState()
    context.addEllipse(in: headRect)
    context.clip()
    let faceColors: [CGColor] = [
        person.skin.blended(withFraction: 0.16, of: .white)?.cgColor ?? person.skin.cgColor,
        person.skin.cgColor,
        skinShadow.cgColor
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: faceColors as CFArray, locations: [0, 0.58, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: headRect.minX, y: headRect.maxY),
                                   end: CGPoint(x: headRect.maxX, y: headRect.minY),
                                   options: [])
    }
    context.restoreGState()

    // 头发：先覆盖整个头顶，再按发型加刘海或马尾。
    let capRect = CGRect(x: headCenter.x - headRadius * 1.03,
                         y: headCenter.y + headRadius * 0.01,
                         width: headRadius * 2.06, height: headRadius * 1.08)
    context.saveGState()
    context.addEllipse(in: capRect)
    context.clip()
    let hairColors: [CGColor] = [
        person.hair.blended(withFraction: 0.34, of: .white)?.cgColor ?? person.hair.cgColor,
        person.hair.cgColor,
        person.hair.cgColor
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: hairColors as CFArray, locations: [0, 0.45, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: capRect.minX, y: capRect.maxY),
                                   end: CGPoint(x: capRect.midX, y: capRect.minY),
                                   options: [])
    }
    context.restoreGState()
    context.setFillColor(person.hair.cgColor)
    switch person.hairStyle {
    case .short, .sidePart:
        // 侧分刘海：右额多一小撮。
        let fringe = CGMutablePath()
        fringe.move(to: CGPoint(x: headCenter.x + headRadius * 0.20, y: headCenter.y + headRadius * 0.66))
        fringe.addLine(to: CGPoint(x: headCenter.x + headRadius * 0.92, y: headCenter.y + headRadius * 0.36))
        fringe.addLine(to: CGPoint(x: headCenter.x + headRadius * 0.50, y: headCenter.y + headRadius * 0.32))
        fringe.closeSubpath()
        context.addPath(fringe)
        context.fillPath()
    case .bowl:
        // 齐刘海。
        context.fill(CGRect(x: headCenter.x - headRadius * 0.96,
                            y: headCenter.y + headRadius * 0.22,
                            width: headRadius * 1.92, height: headRadius * 0.24))
    case .long:
        for side in [CGFloat(-1), CGFloat(1)] {
            context.fill(CGRect(x: headCenter.x + side * headRadius * 0.86 - headRadius * 0.30,
                                y: headCenter.y - headRadius * 1.30,
                                width: headRadius * 0.44, height: headRadius * 2.35))
        }
    case .ponytail:
        for side in [CGFloat(-1), CGFloat(1)] {
            context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 1.05 - headRadius * 0.20,
                                           y: headCenter.y - headRadius * 0.55,
                                           width: headRadius * 0.42, height: headRadius * 1.55))
        }
        if let accessory = person.accessory {
            context.setFillColor(accessory.cgColor)
            for side in [CGFloat(-1), CGFloat(1)] {
                context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 1.02 - headRadius * 0.12,
                                               y: headCenter.y + headRadius * 0.42,
                                               width: headRadius * 0.26, height: headRadius * 0.26))
            }
        }
    }

    // 头发高光，避免整块死黑。
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor)
    context.fillEllipse(in: CGRect(x: headCenter.x - headRadius * 0.62,
                                   y: headCenter.y + headRadius * 0.56,
                                   width: headRadius * 0.74, height: headRadius * 0.26))

    // 五官：眼白 / 虹膜 / 瞳孔 / 眼神光 / 眼睑、眉毛、鼻子、嘴与腮红。
    let eyeY = headCenter.y + headRadius * 0.02
    let eyeOffset = headRadius * 0.38
    let eyeWidth = headRadius * 0.30
    let eyeHeight = headRadius * 0.22
    let irisColor = NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.10, alpha: 1)
    for side in [CGFloat(-1), CGFloat(1)] {
        let eyeRect = CGRect(x: headCenter.x + side * eyeOffset - eyeWidth / 2,
                             y: eyeY - eyeHeight / 2,
                             width: eyeWidth, height: eyeHeight)
        context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 0.95).cgColor)
        context.fillEllipse(in: eyeRect)
        let irisSize = eyeHeight * 0.94
        let irisRect = CGRect(x: eyeRect.midX - irisSize / 2, y: eyeRect.midY - irisSize / 2,
                              width: irisSize, height: irisSize)
        context.setFillColor(irisColor.cgColor)
        context.fillEllipse(in: irisRect)
        let pupilSize = irisSize * 0.50
        context.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: irisRect.midX - pupilSize / 2,
                                       y: irisRect.midY - pupilSize / 2,
                                       width: pupilSize, height: pupilSize))
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
        context.fillEllipse(in: CGRect(x: irisRect.midX - irisSize * 0.02,
                                       y: irisRect.midY + irisSize * 0.16,
                                       width: irisSize * 0.30, height: irisSize * 0.30))
        // 上眼睑
        context.setStrokeColor(person.hair.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(max(1.1, headRadius * 0.05))
        context.move(to: CGPoint(x: eyeRect.minX, y: eyeRect.midY + eyeHeight * 0.10))
        context.addQuadCurve(to: CGPoint(x: eyeRect.maxX, y: eyeRect.midY + eyeHeight * 0.10),
                             control: CGPoint(x: eyeRect.midX, y: eyeRect.maxY + eyeHeight * 0.35))
        context.strokePath()
        // 眉毛
        context.setStrokeColor(person.hair.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(max(1.2, headRadius * 0.085))
        context.move(to: CGPoint(x: headCenter.x + side * headRadius * 0.60, y: eyeY + headRadius * 0.36))
        context.addQuadCurve(to: CGPoint(x: headCenter.x + side * headRadius * 0.16, y: eyeY + headRadius * 0.34),
                             control: CGPoint(x: headCenter.x + side * headRadius * 0.38, y: eyeY + headRadius * 0.50))
        context.strokePath()
        // 腮红
        context.setFillColor(NSColor(calibratedRed: 0.94, green: 0.44, blue: 0.40, alpha: 0.20).cgColor)
        context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 0.62 - headRadius * 0.18,
                                       y: headCenter.y - headRadius * 0.45,
                                       width: headRadius * 0.36, height: headRadius * 0.22))
    }
    // 鼻子：鼻梁一笔，鼻翼两点。
    context.setStrokeColor(skinShadow.withAlphaComponent(0.65).cgColor)
    context.setLineWidth(max(1, headRadius * 0.05))
    context.move(to: CGPoint(x: headCenter.x + headRadius * 0.02, y: eyeY - headRadius * 0.06))
    context.addLine(to: CGPoint(x: headCenter.x - headRadius * 0.02, y: headCenter.y - headRadius * 0.30))
    context.strokePath()
    context.setFillColor(skinShadow.withAlphaComponent(0.75).cgColor)
    for side in [CGFloat(-1), CGFloat(1)] {
        context.fillEllipse(in: CGRect(x: headCenter.x + side * headRadius * 0.09 - headRadius * 0.035,
                                       y: headCenter.y - headRadius * 0.34,
                                       width: headRadius * 0.07, height: headRadius * 0.05))
    }
    // 嘴：下唇 + 微笑唇线。
    let mouthY = headCenter.y - headRadius * 0.50
    context.setFillColor(NSColor(calibratedRed: 0.72, green: 0.34, blue: 0.32, alpha: 0.80).cgColor)
    context.fillEllipse(in: CGRect(x: headCenter.x - headRadius * 0.19, y: mouthY - headRadius * 0.10,
                                   width: headRadius * 0.38, height: headRadius * 0.15))
    context.setStrokeColor(NSColor(calibratedRed: 0.52, green: 0.18, blue: 0.18, alpha: 0.95).cgColor)
    context.setLineWidth(max(1.2, headRadius * 0.07))
    context.move(to: CGPoint(x: headCenter.x - headRadius * 0.22, y: mouthY))
    context.addQuadCurve(to: CGPoint(x: headCenter.x + headRadius * 0.22, y: mouthY),
                         control: CGPoint(x: headCenter.x, y: mouthY - headRadius * 0.16))
    context.strokePath()

    // 爸爸的背包（增强辨识度）。
    if style == .father {
        context.setFillColor(NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.30, alpha: 0.95).cgColor)
        context.fill(CGRect(x: baseX + bodyWidth * 0.40, y: hipY + height * 0.06,
                            width: bodyWidth * 0.26, height: height * 0.22))
    }
    // 妈妈的裙摆。
    if style == .mother {
        context.setFillColor(person.pants.cgColor)
        let skirt = CGMutablePath()
        skirt.move(to: CGPoint(x: baseX - bodyWidth * 0.47, y: hipY + height * 0.02))
        skirt.addLine(to: CGPoint(x: baseX - bodyWidth * 0.74, y: baseY + height * 0.24))
        skirt.addLine(to: CGPoint(x: baseX + bodyWidth * 0.74, y: baseY + height * 0.24))
        skirt.addLine(to: CGPoint(x: baseX + bodyWidth * 0.47, y: hipY + height * 0.02))
        skirt.closeSubpath()
        context.addPath(skirt)
        context.fillPath()
    }
}

/// 一家四口站成一排；先撒一层地面阴影再画人，孩子按种子偶尔举手。
private func drawFamily(_ context: CGContext, rect: CGRect, kids: (elder: CGFloat, younger: CGFloat),
                        anchor: CGFloat, scale: CGFloat, seed: UInt64) {
    let unit = min(rect.width, rect.height)
    let baseY = rect.height * 0.045
    let adultHeight = unit * 0.26 * scale
    let heights: [CGFloat] = [adultHeight, adultHeight * 0.94,
                              adultHeight * kids.elder, adultHeight * kids.younger]
    let gap = adultHeight * 0.33
    let startX = rect.width * anchor - gap * 1.5
    let styles: [PersonStyle] = [.father, .mother, .elder, .younger]
    let color = ink(0.88)

    // 地面投影。
    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * gap
        context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.20).cgColor)
        context.fillEllipse(in: CGRect(x: x - height * 0.16, y: baseY - height * 0.02,
                                       width: height * 0.32, height: height * 0.045))
    }
    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * gap
        let lean: CGFloat = index == 0 ? -1 : (index == 3 ? 1 : 0)
        let pose = index >= 2 ? Int((seed / UInt64(index)) % 3) : 0
        drawPerson(context, baseX: x, baseY: baseY, height: height,
                   style: styles[index], color: color, lean: lean, pose: pose)
    }
    // 小朋友手里的小旗子，增加旅行感。
    let flagX = startX + gap * 3 + heights[3] * 0.10
    let flagY = baseY + heights[3] * 0.78
    context.move(to: CGPoint(x: flagX, y: flagY))
    context.addLine(to: CGPoint(x: flagX, y: flagY + unit * 0.075))
    context.strokePath()
    let flag = CGMutablePath()
    flag.move(to: CGPoint(x: flagX, y: flagY + unit * 0.075))
    flag.addLine(to: CGPoint(x: flagX + unit * 0.032, y: flagY + unit * 0.060))
    flag.addLine(to: CGPoint(x: flagX, y: flagY + unit * 0.045))
    flag.closeSubpath()
    context.setFillColor(NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.22, alpha: 0.95).cgColor)
    context.addPath(flag)
    context.fillPath()
}

/// 淡淡的云带：让天空不像纯色渐变。
private func drawClouds(_ context: CGContext, rect: CGRect, palette: Palette, seed: UInt64) {
    var rng = SeededRandom(seed: seed &+ 61)
    for index in 0..<7 {
        let y = rect.height * (0.58 + CGFloat(index) * 0.045)
        let width = rect.width * (0.16 + CGFloat(rng.next()) * 0.30)
        let x = rect.width * CGFloat(rng.next()) - width * 0.5
        let height = rect.height * (0.012 + CGFloat(rng.next()) * 0.018)
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.06 + CGFloat(rng.next()) * 0.05).cgColor)
        context.fillEllipse(in: CGRect(x: x, y: y, width: width, height: height))
        context.fillEllipse(in: CGRect(x: x + width * 0.25, y: y - height * 0.35,
                                       width: width * 0.55, height: height * 1.1))
    }
}

/// 老数码相机风格的日期水印：2010–2016 的照片才有。
private func drawDateStamp(_ context: CGContext, rect: CGRect, text: String) {
    let size = max(11, rect.width * 0.018)
    let font = NSFont(name: "Courier-Bold", size: size)
        ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.28, alpha: 0.92)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    var ascent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
    let origin = CGPoint(x: rect.maxX - width - rect.width * 0.045,
                         y: rect.height * 0.045)
    context.saveGState()
    context.setShadow(offset: .zero, blur: size * 0.6,
                      color: NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.15, alpha: 0.8).cgColor)
    context.textPosition = origin
    CTLineDraw(line, context)
    context.restoreGState()
}

/// 室内场景不画太阳和云。
private func isIndoor(_ scene: TripScene) -> Bool {
    switch scene {
    case .homeDinner, .birthday, .office, .classroom, .piano, .study,
         .familyPortrait, .supermarket:
        return true
    default:
        return false
    }
}

private func renderTrip(width: Int, height: Int, palette: Palette, scene: TripScene,
                        seed: UInt64, kids: (elder: CGFloat, younger: CGFloat),
                        dateStamp: String?, blur: Double = 0) -> CGImage {
    let context = makeContext(width: width, height: height)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    fillGradient(context, rect: rect, top: palette.top, bottom: palette.bottom)
    var rng = SeededRandom(seed: seed)
    if !isIndoor(scene) {
        drawSun(context, rect: rect, palette: palette,
                x: 0.20 + CGFloat(rng.next()) * 0.60,
                y: 0.52 + CGFloat(rng.next()) * 0.26)
        drawClouds(context, rect: rect, palette: palette, seed: seed)
    }

    var showsFamily = true
    switch scene {
    case .skyline:
        drawSkyline(context, rect: rect, palette: palette, seed: seed)
        drawSea(context, rect: rect, palette: palette, horizon: 0.20)
        drawBoat(context, rect: rect, palette: palette, x: 0.32, baseY: 0.16, width: 0.16)
    case .castle:
        drawCastle(context, rect: rect, palette: palette)
        context.setFillColor(palette.hillB.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.22))
    case .greatWall:
        drawGreatWall(context, rect: rect, palette: palette)
    case .chineseGate:
        drawRoofGate(context, rect: rect, palette: palette, baseY: 0.20,
                     roof: NSColor(calibratedRed: 0.62, green: 0.20, blue: 0.16, alpha: 0.95),
                     wall: NSColor(calibratedRed: 0.58, green: 0.16, blue: 0.14, alpha: 0.95), tiers: 2)
    case .thaiPalace:
        drawRoofGate(context, rect: rect, palette: palette, baseY: 0.20,
                     roof: palette.accent, wall: NSColor(calibratedWhite: 0.94, alpha: 0.92), tiers: 3)
        drawDome(context, rect: rect, x: rect.width * 0.82, baseY: 0.22,
                 width: rect.width * 0.09, color: palette.accent)
    case .beach:
        drawSea(context, rect: rect, palette: palette, horizon: 0.26)
        context.setFillColor(palette.bottom.withAlphaComponent(0.95).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.26))
        drawPalm(context, rect: rect, x: 0.10, baseY: 0.22, height: 0.34, color: ink(0.8))
        drawPalm(context, rect: rect, x: 0.92, baseY: 0.20, height: 0.28, color: ink(0.75))
    case .karst:
        drawKarst(context, rect: rect, palette: palette)
        drawBoat(context, rect: rect, palette: palette, x: 0.30, baseY: 0.12, width: 0.18)
    case .warriors:
        context.setFillColor(palette.hillA.withAlphaComponent(0.6).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.34))
        for row in 0..<2 {
            for column in 0..<7 {
                let x = rect.width * (0.10 + CGFloat(column) * 0.12)
                let y = rect.height * (0.18 + CGFloat(row) * 0.11)
                drawPerson(context, baseX: x, baseY: y, height: rect.height * 0.16,
                           style: .younger, color: ink(0.65))
            }
        }
        showsFamily = false
    case .islandChurch:
        drawSea(context, rect: rect, palette: palette, horizon: 0.22)
        context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 0.94).cgColor)
        context.fill(CGRect(x: rect.width * 0.44, y: rect.height * 0.24,
                            width: rect.width * 0.14, height: rect.height * 0.10))
        context.fill(CGRect(x: rect.width * 0.48, y: rect.height * 0.34,
                            width: rect.width * 0.06, height: rect.height * 0.07))
        context.setFillColor(palette.accent.cgColor)
        context.fill(CGRect(x: rect.width * 0.505, y: rect.height * 0.41,
                            width: rect.width * 0.01, height: rect.height * 0.04))
    case .cherryPagoda:
        drawCherryTrees(context, rect: rect, palette: palette, seed: seed)
        drawPagoda(context, rect: rect, palette: palette, centerX: 0.70, baseY: 0.20,
                   tiers: 5, color: ink(0.78))
    case .fuji:
        drawFuji(context, rect: rect, palette: palette, centerX: 0.52, baseY: 0.24, height: 0.44)
        drawSea(context, rect: rect, palette: palette, horizon: 0.22)
        drawCherryTrees(context, rect: rect, palette: palette, seed: seed &+ 11)
    case .merlion:
        drawSkyline(context, rect: rect, palette: palette, seed: seed &+ 4)
        drawSea(context, rect: rect, palette: palette, horizon: 0.22)
        // 鱼尾狮：白色兽身 + 水柱。
        context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 0.95).cgColor)
        context.fillEllipse(in: CGRect(x: rect.width * 0.28, y: rect.height * 0.26,
                                       width: rect.width * 0.10, height: rect.height * 0.13))
        context.fill(CGRect(x: rect.width * 0.28, y: rect.height * 0.22,
                            width: rect.width * 0.10, height: rect.height * 0.05))
        context.setStrokeColor(palette.glow.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(rect.width * 0.012)
        context.move(to: CGPoint(x: rect.width * 0.33, y: rect.height * 0.26))
        context.addLine(to: CGPoint(x: rect.width * 0.40, y: rect.height * 0.19))
        context.strokePath()
    case .seaTemple:
        drawSea(context, rect: rect, palette: palette, horizon: 0.30)
        // 海中礁石与庙。
        context.setFillColor(ink(0.8).cgColor)
        let rock = CGMutablePath()
        rock.move(to: CGPoint(x: rect.width * 0.58, y: rect.height * 0.10))
        rock.addLine(to: CGPoint(x: rect.width * 0.63, y: rect.height * 0.32))
        rock.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.32))
        rock.addLine(to: CGPoint(x: rect.width * 0.76, y: rect.height * 0.10))
        rock.closeSubpath()
        context.addPath(rock)
        context.fillPath()
        drawPagoda(context, rect: rect, palette: palette, centerX: 0.675, baseY: 0.32,
                   tiers: 2, color: ink(0.55))
    case .snowCanal:
        drawCanal(context, rect: rect, palette: palette, snow: true)
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.08))
    case .eiffel:
        drawLatticeTower(context, rect: rect, centerX: 0.52, baseY: 0.22,
                         height: 0.56, width: 0.36, color: ink(0.78))
        context.setFillColor(palette.hillB.withAlphaComponent(0.6).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.22))
    case .louvre:
        drawLouvre(context, rect: rect, palette: palette)
    case .towerBridge:
        drawSuspension(context, rect: rect, palette: palette,
                       color: NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.62, alpha: 0.95),
                       towers: [0.30, 0.70])
        drawSea(context, rect: rect, palette: palette, horizon: 0.18)
    case .colosseum:
        drawColosseum(context, rect: rect, palette: palette)
    case .canalBoat:
        drawCanal(context, rect: rect, palette: palette, snow: false)
    case .alps:
        drawRidge(context, rect: rect, palette: palette, baseY: 0.24, height: 0.34,
                  peaks: [0.35, 0.80, 0.50, 0.95, 0.42, 0.72, 0.30],
                  color: palette.hillA)
        drawRidge(context, rect: rect, palette: palette, baseY: 0.20, height: 0.22,
                  peaks: [0.20, 0.50, 0.30, 0.62, 0.25, 0.45],
                  color: NSColor(calibratedWhite: 0.98, alpha: 0.85))
        context.setFillColor(palette.hillB.withAlphaComponent(0.9).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.20))
    case .santorini:
        drawSantorniHouses(context, rect: rect, palette: palette)
        drawSea(context, rect: rect, palette: palette, horizon: 0.10)
    case .windmill:
        drawWindmill(context, rect: rect, palette: palette, centerX: 0.62, baseY: 0.18)
        context.setFillColor(palette.hillA.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.18))
    case .liberty:
        drawStatue(context, rect: rect, palette: palette)
        drawSea(context, rect: rect, palette: palette, horizon: 0.18)
    case .timesSquare:
        drawBillboards(context, rect: rect, palette: palette, seed: seed)
    case .goldenGate:
        drawSuspension(context, rect: rect, palette: palette,
                       color: NSColor(calibratedRed: 0.72, green: 0.22, blue: 0.16, alpha: 0.95),
                       towers: [0.26, 0.74])
        drawSea(context, rect: rect, palette: palette, horizon: 0.16)
    case .geyser:
        drawGeyser(context, rect: rect, palette: palette)
        context.setFillColor(palette.hillA.withAlphaComponent(0.8).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.12))
    case .operaHouse:
        drawOperaHouse(context, rect: rect, palette: palette)
        drawSea(context, rect: rect, palette: palette, horizon: 0.18)
    case .reef:
        drawReef(context, rect: rect, palette: palette)
    case .lakeJetty:
        drawJetty(context, rect: rect, palette: palette)
    case .tokyoTower:
        drawLatticeTower(context, rect: rect, centerX: 0.68, baseY: 0.22,
                         height: 0.46, width: 0.22, color: ink(0.75), deckCount: 2, curved: true)
        drawCherryTrees(context, rect: rect, palette: palette, seed: seed &+ 5)
    case .homeDinner:
        drawHomeInterior(context, rect: rect, palette: palette, cake: false)
    case .birthday:
        drawHomeInterior(context, rect: rect, palette: palette, cake: true)
    case .schoolGate:
        drawSchoolGate(context, rect: rect, palette: palette)
    case .park:
        drawPark(context, rect: rect, palette: palette, seed: seed)
    case .supermarket:
        drawSupermarket(context, rect: rect, palette: palette, seed: seed)
    case .office:
        drawOffice(context, rect: rect, palette: palette)
        drawPerson(context, baseX: rect.width * 0.62, baseY: rect.height * 0.10,
                   height: min(rect.width, rect.height) * 0.22,
                   style: .father, color: ink(0.8))
        showsFamily = false
    case .graduation:
        drawSchoolGate(context, rect: rect, palette: palette)
    case .piano:
        drawPianoRoom(context, rect: rect, palette: palette)
        drawPerson(context, baseX: rect.width * 0.46, baseY: rect.height * 0.14,
                   height: min(rect.width, rect.height) * 0.20,
                   style: .elder, color: ink(0.8))
        showsFamily = false
    case .classroom:
        drawClassroom(context, rect: rect, palette: palette)
        showsFamily = false
    case .sportsDay:
        drawSportsDay(context, rect: rect, palette: palette)
        showsFamily = false
    case .safari:
        drawSafari(context, rect: rect, palette: palette)
    case .waterPark:
        drawWaterPark(context, rect: rect, palette: palette)
    case .wedding:
        drawWedding(context, rect: rect, palette: palette)
    case .study:
        drawStudy(context, rect: rect, palette: palette)
        drawPerson(context, baseX: rect.width * 0.38, baseY: rect.height * 0.14,
                   height: min(rect.width, rect.height) * 0.20,
                   style: .elder, color: ink(0.8))
        showsFamily = false
    case .jiuzhaigou:
        drawJiuzhaigou(context, rect: rect, palette: palette)
    case .potala:
        drawPotala(context, rect: rect, palette: palette)
    case .zhangjiajie:
        drawZhangjiajie(context, rect: rect, palette: palette)
    case .huangshan:
        drawHuangshan(context, rect: rect, palette: palette)
    case .familyPortrait:
        drawFamilyPortrait(context, rect: rect, palette: palette)
    case .castleNight:
        drawCastleNight(context, rect: rect, palette: palette, seed: seed)
    }

    // 背景做轻微失焦、人物保持清晰：模拟旅行照的景深，弱化「矢量图」感。
    let backdropSource = context.makeImage()!
    let focusRadius = isIndoor(scene) ? 0 : min(CGFloat(width), CGFloat(height)) * 0.009
    let backdrop = focusRadius > 0 ? blurredImage(backdropSource, radius: focusRadius) : backdropSource

    let final = makeContext(width: width, height: height)
    final.draw(backdrop, in: rect)
    if showsFamily {
        // 人物站在画面一侧，别挡住地标；左右交替让整组照片有变化。
        let anchor: CGFloat = isIndoor(scene) ? 0.5 : (seed % 2 == 0 ? 0.24 : 0.76)
        let scale: CGFloat
        switch scene {
        case .familyPortrait: scale = 2.9
        case .homeDinner, .birthday: scale = 1.8
        case .wedding: scale = 1.4
        default: scale = 1.2
        }
        drawFamily(final, rect: rect, kids: kids, anchor: anchor, scale: scale, seed: seed)
    }
    drawGrain(final, rect: rect, seed: seed)
    drawVignette(final, rect: rect)
    if let dateStamp {
        drawDateStamp(final, rect: rect, text: dateStamp)
    }

    var image = final.makeImage()!
    if blur > 0 {
        image = blurredImage(image, radius: blur)
    }
    return image
}

private func blurredImage(_ image: CGImage, radius: Double) -> CGImage {
    let ciImage = CIImage(cgImage: image)
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage?.cropped(to: ciImage.extent),
          let result = sharedBlurContext.createCGImage(output, from: ciImage.extent) else {
        return image
    }
    return result
}

// MARK: - 写入

private func exifDictionary(date: String, width: Int, height: Int,
                            camera: String, lens: String,
                            gps: (Double, Double)?) -> CFDictionary {
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: date,
        kCGImagePropertyExifDateTimeDigitized: date,
        kCGImagePropertyExifLensModel: lens,
        kCGImagePropertyExifFNumber: 1.8,
        kCGImagePropertyExifExposureTime: 1.0 / 160.0,
        kCGImagePropertyExifISOSpeedRatings: [125],
        kCGImagePropertyExifFocalLength: 35.0,
        kCGImagePropertyExifPixelXDimension: width,
        kCGImagePropertyExifPixelYDimension: height
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "Luma",
        kCGImagePropertyTIFFModel: camera,
        kCGImagePropertyTIFFDateTime: date
    ]
    var gpsDict: [CFString: Any] = [:]
    if let gps {
        let (latitude, longitude) = gps
        gpsDict[kCGImagePropertyGPSLatitude] = abs(latitude)
        gpsDict[kCGImagePropertyGPSLatitudeRef] = latitude >= 0 ? "N" : "S"
        gpsDict[kCGImagePropertyGPSLongitude] = abs(longitude)
        gpsDict[kCGImagePropertyGPSLongitudeRef] = longitude >= 0 ? "E" : "W"
        gpsDict[kCGImagePropertyGPSAltitude] = 12.0
    }
    var root: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff
    ]
    if !gpsDict.isEmpty { root[kCGImagePropertyGPSDictionary] = gpsDict }
    return root as CFDictionary
}

private func writeJPEG(_ image: CGImage, to url: URL, quality: Double,
                       properties: CFDictionary) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.jpeg.identifier as CFString,
                                                            1, nil) else {
        throw NSError(domain: "LumaTestKit", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG 目标：\(url.path)"])
    }
    var props = properties as? [CFString: Any] ?? [:]
    props[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(destination, image, props as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LumaTestKit", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "JPEG 写入失败：\(url.path)"])
    }
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1, nil) else {
        throw NSError(domain: "LumaTestKit", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG 目标：\(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LumaTestKit", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败：\(url.path)"])
    }
}

/// 多帧 GIF：导入后进入「动图」入口，查看器按帧播放。
private func writeGIF(_ frames: [CGImage], to url: URL, frameDelay: Double) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.gif.identifier as CFString,
                                                            frames.count, nil) else {
        throw NSError(domain: "LumaTestKit", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 GIF 目标：\(url.path)"])
    }
    let loop: [CFString: Any] = [kCGImagePropertyGIFLoopCount: 0]
    CGImageDestinationSetProperties(destination,
                                    [kCGImagePropertyGIFDictionary: loop] as CFDictionary)
    for frame in frames {
        let delay: [CFString: Any] = [kCGImagePropertyGIFDelayTime: frameDelay]
        CGImageDestinationAddImage(destination, frame,
                                   [kCGImagePropertyGIFDictionary: delay] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LumaTestKit", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "GIF 写入失败：\(url.path)"])
    }
}

// MARK: - 照片计划

private struct PhotoPlan {
    let album: String
    let name: String
    let palette: String
    let scene: TripScene
    let date: String
    let gps: (Double, Double)?
    let width: Int
    let height: Int
    let camera: String
    let lens: String
    let blur: Double
    /// 清单里的说明：地点 · 年份，方便截图和文档引用。
    let caption: String
}

/// 主线：一个中国家庭（爸爸、妈妈、姐姐、弟弟）2010–2026 年环球旅行。
/// 32 个取景地分布在四大洲，孩子身高随年份增长，老照片带数码相机日期水印。
private func planPhotos() -> [PhotoPlan] {
    typealias Item = (name: String, palette: String, scene: TripScene,
                      gps: (Double, Double), date: String)
    let albums: [(String, [Item])] = [
        ("2010-2013 第一次出发", [
            ("2010-07-18 香港 维多利亚港", "harbor", .skyline, (22.2930, 114.1694), "2010:07:18 17:40:00"),
            ("2010-07-19 香港 迪士尼", "golden", .castle, (22.3130, 114.0413), "2010:07:19 11:05:00"),
            ("2011-05-02 北京 长城", "forest", .greatWall, (40.4319, 116.5704), "2011:05:02 09:20:00"),
            ("2011-05-04 北京 天安门", "amber", .chineseGate, (39.9087, 116.3975), "2011:05:04 10:35:00"),
            ("2011-08-11 三亚 亚龙湾", "harbor", .beach, (18.2200, 109.6400), "2011:08:11 16:10:00"),
            ("2012-06-15 桂林 漓江", "forest", .karst, (25.2736, 110.2900), "2012:06:15 08:50:00"),
            ("2012-10-03 西安 兵马俑", "desert", .warriors, (34.3841, 109.2785), "2012:10:03 14:15:00"),
            ("2013-04-06 厦门 鼓浪屿", "harbor", .islandChurch, (24.4470, 118.0670), "2013:04:06 15:30:00")
        ]),
        ("2010-2016 家里日常", [
            ("2010-12-31 北京 家里年夜饭", "home", .homeDinner, (39.9042, 116.4074), "2010:12:31 18:30:00"),
            ("2011-09-01 北京 姐姐上小学", "spring", .schoolGate, (39.9800, 116.3100), "2011:09:01 07:40:00"),
            ("2012-03-18 北京 弟弟上幼儿园", "forest", .schoolGate, (39.9700, 116.3200), "2012:03:18 08:10:00"),
            ("2013-06-01 北京 小区公园", "spring", .park, (39.9600, 116.3300), "2013:06:01 16:20:00"),
            ("2014-02-14 北京 超市采购", "home", .supermarket, (39.9500, 116.3400), "2014:02:14 19:05:00"),
            ("2015-07-12 北京 爸爸的办公室", "harbor", .office, (39.9087, 116.4600), "2015:07:12 15:30:00"),
            ("2016-01-09 北京 客厅生日会", "home", .birthday, (39.9042, 116.4074), "2016:01:09 19:40:00"),
            ("2016-06-25 北京 姐姐小学毕业", "spring", .graduation, (39.9800, 116.3100), "2016:06:25 10:15:00")
        ]),
        ("2014-2017 亚洲邻居", [
            ("2014-03-30 东京 塔下樱花", "kyoto", .tokyoTower, (35.6586, 139.7454), "2014:03:30 10:20:00"),
            ("2014-03-28 京都 清水寺", "kyoto", .cherryPagoda, (34.9949, 135.7850), "2014:03:28 09:10:00"),
            ("2014-04-02 河口湖 富士山", "snow", .fuji, (35.5171, 138.7519), "2014:04:02 07:45:00"),
            ("2015-07-20 新加坡 鱼尾狮", "harbor", .merlion, (1.2868, 103.8545), "2015:07:20 18:05:00"),
            ("2015-07-23 巴厘岛 海神庙", "amber", .seaTemple, (-8.6212, 115.0868), "2015:07:23 17:25:00"),
            ("2016-01-26 曼谷 大皇宫", "golden", .thaiPalace, (13.7500, 100.4913), "2016:01:26 14:40:00"),
            ("2016-08-14 首尔 景福宫", "amber", .chineseGate, (37.5796, 126.9770), "2016:08:14 11:15:00"),
            ("2017-12-30 北海道 小樽运河", "snow", .snowCanal, (43.1990, 141.0030), "2017:12:30 16:30:00")
        ]),
        ("2017-2021 周末与补课", [
            ("2017-10-20 北京 秋季运动会", "spring", .sportsDay, (39.9800, 116.3100), "2017:10:20 09:00:00"),
            ("2019-05-01 广州 长隆野生动物世界", "desert", .safari, (23.0040, 113.3300), "2019:05:01 10:20:00"),
            ("2019-05-03 广州 长隆水上乐园", "pool", .waterPark, (23.0080, 113.3350), "2019:05:03 14:10:00"),
            ("2019-08-17 上海 迪士尼乐园", "golden", .castle, (31.1434, 121.6570), "2019:08:17 11:30:00"),
            ("2020-06-20 北京 表姐婚礼", "kyoto", .wedding, (39.9400, 116.4200), "2020:06:20 11:50:00"),
            ("2021-07-10 北京 周末写作业", "home", .study, (39.9042, 116.4074), "2021:07:10 15:00:00"),
            ("2018-03-11 北京 钢琴课", "home", .piano, (39.9300, 116.4500), "2018:03:11 10:00:00"),
            ("2018-04-15 北京 奥数培训班", "amber", .classroom, (39.9200, 116.4300), "2018:04:15 09:30:00")
        ]),
        ("2018-2021 欧洲夏天", [
            ("2018-07-12 巴黎 埃菲尔铁塔", "paris", .eiffel, (48.8584, 2.2945), "2018:07:12 20:10:00"),
            ("2018-07-10 巴黎 卢浮宫", "paris", .louvre, (48.8606, 2.3376), "2018:07:10 15:20:00"),
            ("2018-07-16 伦敦 塔桥", "paris", .towerBridge, (51.5055, -0.0754), "2018:07:16 10:05:00"),
            ("2019-06-20 罗马 斗兽场", "golden", .colosseum, (41.8902, 12.4922), "2019:06:20 09:45:00"),
            ("2019-06-24 威尼斯 运河", "amber", .canalBoat, (45.4341, 12.3388), "2019:06:24 17:50:00"),
            ("2019-06-28 瑞士 因特拉肯", "snow", .alps, (46.6863, 7.8632), "2019:06:28 08:30:00"),
            ("2020-01-05 圣托里尼 伊亚", "santorini", .santorini, (36.4618, 25.3753), "2020:01:05 18:35:00"),
            ("2021-08-02 阿姆斯特丹 风车村", "spring", .windmill, (52.4750, 4.8200), "2021:08:02 13:10:00")
        ]),
        ("2022-2026 跨过海洋", [
            ("2022-07-18 纽约 时代广场", "city", .timesSquare, (40.7580, -73.9855), "2022:07:18 21:15:00"),
            ("2022-07-20 纽约 自由女神", "harbor", .liberty, (40.6892, -74.0445), "2022:07:20 10:40:00"),
            ("2023-02-11 旧金山 金门大桥", "amber", .goldenGate, (37.8199, -122.4783), "2023:02:11 16:55:00"),
            ("2023-02-15 黄石 大棱镜", "amber", .geyser, (44.4605, -110.8281), "2023:02:15 12:20:00"),
            ("2024-07-05 悉尼 歌剧院", "harbor", .operaHouse, (-33.8568, 151.2153), "2024:07:05 17:30:00"),
            ("2024-07-09 大堡礁 浮潜", "reef", .reef, (-18.2871, 147.6992), "2024:07:09 11:00:00"),
            ("2025-01-20 皇后镇 湖湾", "snow", .lakeJetty, (-45.0312, 168.6626), "2025:01:20 09:35:00"),
            ("2026-04-12 东京 塔下重逢", "kyoto", .tokyoTower, (35.6586, 139.7454), "2026:04:12 18:20:00")
        ]),
        ("2022-2026 国内山河", [
            ("2022-08-06 四川 九寨沟", "jiuzhai", .jiuzhaigou, (33.2600, 103.9180), "2022:08:06 10:40:00"),
            ("2023-07-15 西藏 布达拉宫", "snow", .potala, (29.6578, 91.1172), "2023:07:15 15:20:00"),
            ("2023-10-02 湖南 张家界", "forest", .zhangjiajie, (29.1170, 110.4790), "2023:10:02 09:50:00"),
            ("2024-04-05 安徽 黄山", "snow", .huangshan, (30.1300, 118.1700), "2024:04:05 06:50:00"),
            ("2024-08-10 上海 迪士尼烟花", "golden", .castleNight, (31.1434, 121.6570), "2024:08:10 20:40:00"),
            ("2025-05-01 珠海 长隆海洋王国", "pool", .waterPark, (22.1000, 113.5300), "2025:05:01 11:10:00"),
            ("2025-08-20 海南 三亚水世界", "pool", .waterPark, (18.2200, 109.6400), "2025:08:20 14:30:00"),
            ("2026-02-18 北京 全家福", "home", .familyPortrait, (39.9042, 116.4074), "2026:02:18 18:00:00")
        ])
    ]

    func camera(forYear year: Int) -> (String, String) {
        cameraAndLens(forYear: year)
    }

    var plans: [PhotoPlan] = []
    for (album, items) in albums {
        for item in items {
            let year = Int(item.date.prefix(4)) ?? 2010
            let (camera, lens) = camera(forYear: year)
            // 竖幅留给人像感强的地标：铁塔、富士山、自由女神、东京塔。
            let portrait = [.eiffel, .fuji, .liberty, .tokyoTower].contains(where: { $0 == item.scene })
                && item.name.contains("2026") == false
            let place = item.name.split(separator: " ").dropFirst().prefix(2)
                .joined(separator: " ")
            plans.append(PhotoPlan(album: album,
                                   name: item.name,
                                   palette: item.palette,
                                   scene: item.scene,
                                   date: item.date,
                                   gps: item.gps,
                                   width: portrait ? 3024 : 2400,
                                   height: portrait ? 4032 : 1600,
                                   camera: camera,
                                   lens: lens,
                                   blur: 0,
                                   caption: "\(place) · \(year)"))
        }
    }
    return plans
}

/// 2010–2026 年孩子的身高比例：姐姐从 6 岁长到 22 岁，弟弟从 2 岁长到 18 岁。
private func kidsScale(for date: String) -> (elder: CGFloat, younger: CGFloat) {
    let year = Int(date.prefix(4)) ?? 2010
    let step = CGFloat(max(0, min(16, year - 2010)))
    return (min(1.0, 0.56 + step * 0.028), min(0.92, 0.40 + step * 0.033))
}

private func dateStamp(for date: String) -> String? {
    let year = Int(date.prefix(4)) ?? 2010
    guard year <= 2016 else { return nil }
    let parts = date.prefix(10).split(separator: ":")
    guard parts.count == 3 else { return nil }
    return "\(parts[0]).\(parts[1]).\(parts[2])"
}

private func cameraAndLens(forYear year: Int) -> (String, String) {
    switch year {
    case ...2013: return ("Canon PowerShot S90", "28mm F2.0")
    case ...2017: return ("Sony NEX-5T", "35mm F1.8")
    case ...2021: return ("Luma Camera X", "24mm F1.8")
    default: return ("Luma Phone 2", "26mm F1.6")
    }
}

/// 规模化测试集：把 56 个故事线场景循环铺到 2010–2026 的每一年，
/// 用不同的日期、GPS 偏移与渲染种子生成 `count` 张照片（可到 5000+）。
private func scalePlans(count: Int) -> [PhotoPlan] {
    let templates = planPhotos()
    guard !templates.isEmpty, count > 0 else { return templates }
    var plans: [PhotoPlan] = []
    plans.reserveCapacity(count)
    for index in 0..<count {
        let template = templates[index % templates.count]
        let year = 2010 + (index * 17 / count)
        var rng = SeededRandom(seed: UInt64(2010 + index) &* 7919)
        let month = (index * 7) % 12 + 1
        let day = (index * 11) % 27 + 1
        let hour = 7 + (index * 5) % 12
        let minute = (index * 13) % 60
        let date = String(format: "%d:%02d:%02d %02d:%02d:00", year, month, day, hour, minute)
        let prefix = String(format: "%d-%02d-%02d", year, month, day)
        let jitterLat = (rng.next() - 0.5) * 0.06
        let jitterLon = (rng.next() - 0.5) * 0.06
        let gps = template.gps.map { ($0.0 + jitterLat, $0.1 + jitterLon) }
        let (camera, lens) = cameraAndLens(forYear: year)
        let place = template.caption.split(separator: "·").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? template.name
        plans.append(PhotoPlan(album: "\(year) 年",
                               name: String(format: "%@ %@ %05d", prefix, place, index),
                               palette: template.palette,
                               scene: template.scene,
                               date: date,
                               gps: gps,
                               width: template.width,
                               height: template.height,
                               camera: camera,
                               lens: lens,
                               blur: 0,
                               caption: "\(place) · \(year)"))
    }
    return plans
}

// MARK: - 主流程

private func parseArguments() -> (out: URL, posters: URL?, faces: URL?, force: Bool, photoCount: Int) {
    var out = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Movies/LumaTestKit/dataset")
    var posters: URL?
    var faces: URL?
    var force = false
    var photoCount = 0
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--out":
            if let value = iterator.next() { out = URL(fileURLWithPath: value) }
        case "--posters-json":
            if let value = iterator.next() { posters = URL(fileURLWithPath: value) }
        case "--faces-dir":
            if let value = iterator.next() { faces = URL(fileURLWithPath: value) }
        case "--photo-count":
            if let value = iterator.next() { photoCount = max(0, Int(value) ?? 0) }
        case "--force":
            force = true
        default:
            break
        }
    }
    return (out, posters, faces, force, photoCount)
}

private struct ManifestEntry {
    let path: String
    let kind: String
    let note: String
    let date: String?
    let latitude: Double?
    let longitude: Double?
}

private func main() throws {
    let (out, postersJSON, facesDir, force, photoCount) = parseArguments()
    faceAssets = FaceAssets.load(from: facesDir)
    if faceAssets != nil { print("使用真人素材：\(facesDir?.path ?? "")") }
    let fm = FileManager.default
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    var manifest: [ManifestEntry] = []

    // 1) 相册照片：一家四口 2010–2026 的环球旅行（可切换到 5000+ 张规模模式）
    let plans = photoCount > 0 ? scalePlans(count: photoCount) : planPhotos()
    // 清理上一版相簿里已经不在计划中的照片，避免时间轴混入旧素材。
    let expected = Set(plans.map {
        out.appendingPathComponent("photos/\($0.album)/\($0.name).jpg").standardizedFileURL.path
    })
    if let enumerator = fm.enumerator(at: out.appendingPathComponent("photos"),
                                      includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "jpg"
            && !expected.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
    }
    for plan in plans {
        let url = out.appendingPathComponent("photos/\(plan.album)/\(plan.name).jpg")
        if !force && fm.fileExists(atPath: url.path) { continue }
        let seed = UInt64(abs(plan.name.hashValue % 100000) + 7)
        let image = renderTrip(width: plan.width, height: plan.height,
                               palette: palette(named: plan.palette),
                               scene: plan.scene, seed: seed,
                               kids: kidsScale(for: plan.date),
                               dateStamp: dateStamp(for: plan.date),
                               blur: plan.blur)
        let props = exifDictionary(date: plan.date, width: plan.width, height: plan.height,
                                   camera: plan.camera, lens: plan.lens, gps: plan.gps)
        try writeJPEG(image, to: url, quality: 0.82, properties: props)
        manifest.append(ManifestEntry(path: url.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: "photo", note: plan.caption,
                                      date: plan.date,
                                      latitude: plan.gps?.0, longitude: plan.gps?.1))
    }

    // 2) 截屏（PNG，浅色/深色各 3 张）
    for index in 0..<6 {
        let name = String(format: "Screenshot 2026-11-%02d at 21.%02d.%02d.png",
                          10 + index, 10 + index * 3, index * 7)
        let url = out.appendingPathComponent("screenshots/\(name)")
        if !force && fm.fileExists(atPath: url.path) { continue }
        let image = renderScreenshot(width: 2880, height: 1800, seed: UInt64(index + 1),
                                     dark: index % 2 == 1)
        try writePNG(image, to: url)
        manifest.append(ManifestEntry(path: url.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: "screenshot", note: "桌面截屏 \(index + 1)",
                                      date: nil, latitude: nil, longitude: nil))
    }

    // 3) 实况照片的静态端：2024 悉尼歌剧院、2025 皇后镇湖湾
    let livePlans: [(String, String, TripScene, (Double, Double), String)] = [
        ("2024:07:05 17:30:00", "harbor", .operaHouse, (-33.8568, 151.2153), "悉尼歌剧院"),
        ("2025:01:20 09:35:00", "snow", .lakeJetty, (-45.0312, 168.6626), "皇后镇湖湾")
    ]
    for (index, item) in livePlans.enumerated() {
        let url = out.appendingPathComponent("live/IMG_\(String(format: "%04d", 100 + index)).jpg")
        if !force && fm.fileExists(atPath: url.path) { continue }
        let image = renderTrip(width: 2400, height: 1800,
                               palette: palette(named: item.1), scene: item.2,
                               seed: UInt64(900 + index),
                               kids: kidsScale(for: item.0),
                               dateStamp: dateStamp(for: item.0))
        let props = exifDictionary(date: item.0, width: 2400, height: 1800,
                                   camera: "Luma Phone 2", lens: "26mm F1.6",
                                   gps: item.3)
        try writeJPEG(image, to: url, quality: 0.85, properties: props)
        manifest.append(ManifestEntry(path: url.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: "live", note: "实况照片 · \(item.4)",
                                      date: item.0, latitude: item.3.0, longitude: item.3.1))
    }

    // 2.5) 媒体类型样本：自拍 / 全景 / 动图 / RAW
    //      侧边栏「媒体类型」按文件名、画幅与扩展名归类，这几组让每个入口都有内容。
    struct MediaSample {
        let folder: String
        let name: String
        let scene: TripScene
        let paletteName: String
        let width: Int
        let height: Int
        let date: String
        let gps: (Double, Double)?
        let note: String
    }
    let mediaSamples: [MediaSample] = [
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2025-02-14 家里客厅",
                    scene: .familyPortrait, paletteName: "home", width: 1600, height: 1200,
                    date: "2025:02:14 19:20:00", gps: (31.2304, 121.4737), note: "自拍 · 春节客厅"),
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2024-08-03 长隆水上乐园",
                    scene: .waterPark, paletteName: "pool", width: 1600, height: 1200,
                    date: "2024:08:03 15:10:00", gps: (23.0067, 113.4956), note: "自拍 · 长隆水世界"),
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2025-07-19 三亚海边",
                    scene: .beach, paletteName: "reef", width: 1600, height: 1200,
                    date: "2025:07:19 17:40:00", gps: (18.2528, 109.5120), note: "自拍 · 三亚海边"),
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2026-01-01 家里客厅",
                    scene: .homeDinner, paletteName: "home", width: 1600, height: 1200,
                    date: "2026:01:01 10:05:00", gps: (31.2304, 121.4737), note: "自拍 · 元旦"),
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2024-10-05 黄山云海",
                    scene: .huangshan, paletteName: "snow", width: 1600, height: 1200,
                    date: "2024:10:05 09:30:00", gps: (30.1318, 118.1636), note: "自拍 · 黄山"),
        MediaSample(folder: "2024-2026 自拍", name: "自拍 2025-10-01 九寨沟",
                    scene: .jiuzhaigou, paletteName: "jiuzhai", width: 1600, height: 1200,
                    date: "2025:10:01 11:20:00", gps: (33.2600, 103.9180), note: "自拍 · 九寨沟"),
        MediaSample(folder: "2019 全景足迹", name: "全景 2019-06-28 瑞士雪山",
                    scene: .alps, paletteName: "snow", width: 5000, height: 1250,
                    date: "2019:06:28 08:30:00", gps: (46.5600, 8.5600), note: "全景 · 瑞士雪山"),
        MediaSample(folder: "2019 全景足迹", name: "全景 2021-10-05 九寨沟彩池",
                    scene: .jiuzhaigou, paletteName: "jiuzhai", width: 6000, height: 1500,
                    date: "2021:10:05 10:10:00", gps: (33.2600, 103.9180), note: "全景 · 九寨沟"),
        MediaSample(folder: "2019 全景足迹", name: "全景 2023-04-02 长城",
                    scene: .greatWall, paletteName: "golden", width: 5200, height: 1300,
                    date: "2023:04:02 09:00:00", gps: (40.3560, 116.0200), note: "全景 · 长城"),
        MediaSample(folder: "2026 摄影练习", name: "RAW 2026-05-02 黄山云海",
                    scene: .huangshan, paletteName: "snow", width: 2400, height: 1600,
                    date: "2026:05:02 07:40:00", gps: (30.1318, 118.1636), note: "RAW · 黄山"),
        MediaSample(folder: "2026 摄影练习", name: "RAW 2026-06-18 布达拉宫",
                    scene: .potala, paletteName: "desert", width: 2400, height: 1600,
                    date: "2026:06:18 16:20:00", gps: (29.6578, 91.1172), note: "RAW · 布达拉宫")
    ]
    for sample in mediaSamples {
        // RAW 用 .dng 扩展名、内容仍是 JPEG：缩略图能解，媒体类型按扩展名归到 RAW。
        let ext = sample.name.hasPrefix("RAW") ? "dng" : "jpg"
        let url = out.appendingPathComponent("photos/\(sample.folder)/\(sample.name).\(ext)")
        if !force && fm.fileExists(atPath: url.path) { continue }
        let seed = UInt64(abs(sample.name.hashValue % 100000) + 11)
        let image = renderTrip(width: sample.width, height: sample.height,
                               palette: palette(named: sample.paletteName), scene: sample.scene,
                               seed: seed, kids: kidsScale(for: sample.date),
                               dateStamp: dateStamp(for: sample.date))
        let props = exifDictionary(date: sample.date, width: sample.width, height: sample.height,
                                   camera: "Luma Phone 2", lens: "24mm F1.8", gps: sample.gps)
        try writeJPEG(image, to: url, quality: 0.84, properties: props)
        let kind = sample.name.hasPrefix("RAW") ? "raw"
            : (sample.name.hasPrefix("全景") ? "panorama" : "selfie")
        manifest.append(ManifestEntry(path: url.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: kind, note: sample.note, date: sample.date,
                                      latitude: sample.gps?.0, longitude: sample.gps?.1))
    }

    // 动图：两帧 GIF，导入后进入「动图」入口。
    let gifURL = out.appendingPathComponent("photos/2024-2026 家里的笑声/动图 2026-01-01 姐弟做鬼脸.gif")
    if force || !fm.fileExists(atPath: gifURL.path) {
        let frames = (0..<2).map { index in
            renderTrip(width: 960, height: 720, palette: palette(named: "home"),
                       scene: .homeDinner, seed: UInt64(1500 + index),
                       kids: kidsScale(for: "2026:01:01 12:00:00"), dateStamp: nil)
        }
        try writeGIF(frames, to: gifURL, frameDelay: 0.35)
        manifest.append(ManifestEntry(path: gifURL.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: "animated", note: "动图 · 姐弟做鬼脸",
                                      date: "2026:01:01 12:00:00", latitude: nil, longitude: nil))
    }

    // 4) 回归素材：重复 / 近似 / 模糊 / 全景 / 竖幅 / 损坏
    let variants: [(String, String, TripScene, Int, Int, Double, String, String)] = [
        ("duplicate_01.jpg", "paris", .eiffel, 2400, 1600, 0, "2018:07:10 20:10:00", "巴黎铁塔"),
        ("near_duplicate_01.jpg", "paris", .eiffel, 2380, 1580, 1.2, "2018:07:10 20:10:01", "巴黎铁塔"),
        ("blurred_01.jpg", "reef", .reef, 2400, 1600, 14, "2024:07:09 11:00:00", "大堡礁"),
        ("panorama_01.jpg", "snow", .alps, 5000, 1250, 0, "2019:06:28 08:30:00", "瑞士雪山全景"),
        ("portrait_01.jpg", "santorini", .santorini, 2400, 3600, 0, "2020:01:05 18:35:00", "圣托里尼")
    ]
    for item in variants {
        let url = out.appendingPathComponent("variants/\(item.0)")
        if !force && fm.fileExists(atPath: url.path) { continue }
        let image = renderTrip(width: item.3, height: item.4,
                               palette: palette(named: item.1), scene: item.2,
                               seed: 4242, kids: kidsScale(for: item.6),
                               dateStamp: dateStamp(for: item.6), blur: item.5)
        let props = exifDictionary(date: item.6, width: item.3, height: item.4,
                                   camera: "Luma Camera X", lens: "24mm F1.8", gps: nil)
        try writeJPEG(image, to: url, quality: 0.8, properties: props)
        manifest.append(ManifestEntry(path: url.path.replacingOccurrences(of: out.path + "/", with: ""),
                                      kind: "variant", note: item.7, date: nil,
                                      latitude: nil, longitude: nil))
    }
    let duplicateSource = out.appendingPathComponent("photos/2018-2021 欧洲夏天/2018-07-12 巴黎 埃菲尔铁塔.jpg")
    let duplicateTarget = out.appendingPathComponent("variants/duplicate_01.jpg")
    if fm.fileExists(atPath: duplicateSource.path) {
        try? fm.removeItem(at: duplicateTarget)
        try? fm.copyItem(at: duplicateSource, to: duplicateTarget)
    }
    // 损坏文件：保留 JPEG 头与一段数据，解码必定失败。
    let corrupt = out.appendingPathComponent("variants/corrupt_01.jpg")
    if force || !fm.fileExists(atPath: corrupt.path) {
        if let data = try? Data(contentsOf: out.appendingPathComponent(
            "photos/2018-2021 欧洲夏天/2018-07-10 巴黎 卢浮宫.jpg")) {
            try data.prefix(4096).write(to: corrupt)
            manifest.append(ManifestEntry(path: corrupt.path.replacingOccurrences(of: out.path + "/", with: ""),
                                          kind: "corrupt", note: "截断的 JPEG",
                                          date: nil, latitude: nil, longitude: nil))
        }
    }

    // 5) 海报：网络影院 / 影院共用
    if let postersJSON,
       let data = try? Data(contentsOf: postersJSON),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let items = root["items"] as? [[String: Any]] {
        for item in items {
            guard let file = item["file"] as? String,
                  let title = item["title"] as? String else { continue }
            let url = out.appendingPathComponent(file)
            if !force && fm.fileExists(atPath: url.path) { continue }
            let seed = UInt64(abs(title.hashValue % 100000) + 31)
            let paletteName = item["palette"] as? String ?? "city"
            let subtitle = item["subtitle"] as? String ?? ""
            let poster = renderPoster(width: 600, height: 900, title: title,
                                      subtitle: subtitle, palette: palette(named: paletteName),
                                      seed: seed)
            try writeJPEG(poster, to: url, quality: 0.86,
                          properties: exifDictionary(date: "2026:11:20 12:00:00",
                                                     width: 600, height: 900,
                                                     camera: "Luma Cinema", lens: "-",
                                                     gps: nil))
            manifest.append(ManifestEntry(path: file, kind: "poster", note: title,
                                          date: nil, latitude: nil, longitude: nil))

            let fanartFile = "catalog/fanart/" + (file as NSString).lastPathComponent
                .replacingOccurrences(of: ".jpg", with: "_fanart.jpg")
            let fanartURL = out.appendingPathComponent(fanartFile)
            if force || !fm.fileExists(atPath: fanartURL.path) {
                let fanart = renderBackdrop(width: 1280, height: 720, palette: palette(named: paletteName),
                                            seed: seed &+ 5)
                try writeJPEG(fanart, to: fanartURL, quality: 0.84,
                              properties: exifDictionary(date: "2026:11:20 12:00:00",
                                                         width: 1280, height: 720,
                                                         camera: "Luma Cinema", lens: "-",
                                                         gps: nil))
            }
        }
    }

    let manifestObject: [String: Any] = [
        "schemaVersion": 1,
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
        "items": manifest.map { entry -> [String: Any] in
            var dict: [String: Any] = ["path": entry.path, "kind": entry.kind, "note": entry.note]
            if let date = entry.date { dict["date"] = date }
            if let latitude = entry.latitude { dict["latitude"] = latitude }
            if let longitude = entry.longitude { dict["longitude"] = longitude }
            return dict
        }
    ]
    let manifestURL = out.appendingPathComponent("image_manifest.json")
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObject,
                                                  options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: manifestURL, options: .atomic)
    print("图片素材完成：\(out.path)（\(manifest.count) 个文件）")
}

// MARK: - 海报 / 截屏

private func renderPoster(width: Int, height: Int, title: String, subtitle: String,
                          palette: Palette, seed: UInt64) -> CGImage {
    let context = makeContext(width: width, height: height)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    fillGradient(context, rect: rect, top: palette.top, bottom: palette.bottom)
    drawCity(context, rect: CGRect(x: 0, y: 0, width: width, height: height / 2),
             palette: palette, seed: seed)
    drawGlow(context, center: CGPoint(x: rect.midX, y: rect.height * 0.72),
             radius: CGFloat(width) * 0.7, color: palette.glow)
    drawBokeh(context, rect: rect, palette: palette, seed: seed &+ 2, count: 40)

    // 底部渐变遮罩，保证标题可读。
    let colors = [NSColor.clear.cgColor, NSColor(calibratedWhite: 0, alpha: 0.75).cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.45, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX, y: rect.height * 0.55),
                                   end: CGPoint(x: rect.midX, y: 0), options: [])
    }
    drawText(context, title, at: CGPoint(x: 48, y: 150), size: 46, maxWidth: CGFloat(width - 96))
    if !subtitle.isEmpty {
        drawText(context, subtitle, at: CGPoint(x: 48, y: 104), size: 24,
                 weight: .medium, color: NSColor(calibratedWhite: 1, alpha: 0.82),
                 maxWidth: CGFloat(width - 96))
    }
    return context.makeImage()!
}

private func renderBackdrop(width: Int, height: Int, palette: Palette, seed: UInt64) -> CGImage {
    let context = makeContext(width: width, height: height)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    fillGradient(context, rect: rect, top: palette.top, bottom: palette.bottom)
    drawCity(context, rect: rect, palette: palette, seed: seed)
    drawGlow(context, center: CGPoint(x: rect.width * 0.7, y: rect.height * 0.65),
             radius: CGFloat(width) * 0.4, color: palette.glow)
    return context.makeImage()!
}

private func renderScreenshot(width: Int, height: Int, seed: UInt64, dark: Bool) -> CGImage {
    let context = makeContext(width: width, height: height)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    let wallpaper = dark ? palettes[2] : palettes[4]
    fillGradient(context, rect: rect, top: wallpaper.top, bottom: wallpaper.bottom)
    drawGlow(context, center: CGPoint(x: rect.width * 0.25, y: rect.height * 0.75),
             radius: CGFloat(width) * 0.5, color: wallpaper.glow)

    // 菜单栏
    context.setFillColor(NSColor(calibratedWhite: dark ? 0.08 : 0.96, alpha: 0.72).cgColor)
    context.fill(CGRect(x: 0, y: rect.height - 44, width: rect.width, height: 44))
    drawText(context, "拾光", at: CGPoint(x: 34, y: rect.height - 32), size: 20,
             weight: .semibold, color: dark ? .white : .black)
    drawText(context, "文件  编辑  显示  接入  帮助", at: CGPoint(x: 120, y: rect.height - 31),
             size: 16, weight: .regular, color: dark ? .white : .black)

    // 主窗口
    let windowRect = CGRect(x: 120, y: 120, width: rect.width - 240, height: rect.height - 260)
    let windowPath = CGPath(roundedRect: windowRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.setFillColor(NSColor(calibratedWhite: dark ? 0.12 : 0.99, alpha: 0.96).cgColor)
    context.addPath(windowPath)
    context.fillPath()
    context.setStrokeColor(NSColor(calibratedWhite: dark ? 0.32 : 0.86, alpha: 1).cgColor)
    context.setLineWidth(1.5)
    context.addPath(windowPath)
    context.strokePath()

    // 侧边栏
    context.setFillColor(NSColor(calibratedWhite: dark ? 0.17 : 0.95, alpha: 1).cgColor)
    context.fill(CGRect(x: windowRect.minX, y: windowRect.minY,
                        width: 260, height: windowRect.height))
    for index in 0..<8 {
        let y = windowRect.maxY - 120 - CGFloat(index) * 54
        context.setFillColor(NSColor(calibratedWhite: dark ? 0.78 : 0.28,
                                     alpha: index == 1 ? 0.95 : 0.55).cgColor)
        context.fill(CGRect(x: windowRect.minX + 30, y: y, width: CGFloat(90 + (index % 3) * 40),
                            height: 14))
    }

    // 照片网格
    var rng = SeededRandom(seed: seed)
    let gridOrigin = CGPoint(x: windowRect.minX + 300, y: windowRect.minY + 120)
    let cellWidth = (windowRect.width - 360) / 5
    for row in 0..<4 {
        for column in 0..<5 {
            let cell = CGRect(x: gridOrigin.x + CGFloat(column) * cellWidth,
                              y: gridOrigin.y + CGFloat(row) * (cellWidth * 0.72 + 10),
                              width: cellWidth - 10, height: cellWidth * 0.72)
            let palette = palettes[rng.int(0...(palettes.count - 1))]
            context.setFillColor(palette.hillA.withAlphaComponent(0.9).cgColor)
            context.fill(cell)
            drawGlow(context, center: CGPoint(x: cell.midX, y: cell.midY),
                     radius: cell.width * 0.6, color: palette.accent)
        }
    }
    drawText(context, "截屏 · 2026-11-20", at: CGPoint(x: windowRect.minX + 300,
                                                       y: windowRect.maxY - 70),
             size: 26, weight: .bold, color: dark ? .white : .black)
    drawText(context, "Screenshot", at: CGPoint(x: windowRect.maxX - 220,
                                                 y: windowRect.maxY - 66),
             size: 16, weight: .medium, color: dark ? .white : .black)
    return context.makeImage()!
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("图片素材生成失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
