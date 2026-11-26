import SwiftUI
import CoreImage
import AppKit

// MARK: - 二维码矩阵

/// 把文本编码成二维码矩阵：`true` 表示深色模块。
/// 自己取矩阵而不是直接贴 `CIImage`，是为了把模块画成圆角并做渐变。
enum QRCodeMatrix {
    static func make(_ text: String, correction: String = "H") -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(output, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let bitmap = CGContext(data: &pixels,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bitmap.interpolationQuality = .none
        // CoreGraphics 原点在左下：翻转一次，让第 0 行是二维码顶部，
        // 否则画出来的码是上下颠倒的，扫不出来。
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var matrix: [[Bool]] = []
        matrix.reserveCapacity(height)
        for y in 0..<height {
            var row = [Bool](repeating: false, count: width)
            for x in 0..<width {
                row[x] = pixels[y * width + x] < 128
            }
            matrix.append(row)
        }
        return matrix
    }
}

// MARK: - 高级版二维码

/// 圆角模块 + 渐变墨色 + 自带留白；中心可叠品牌标识，四周留白保证可扫。
struct StyledQRCode: View {
    let text: String
    var colors: [Color] = [Color(red: 0.09, green: 0.36, blue: 0.96),
                           Color(red: 0.16, green: 0.74, blue: 0.92)]
    var quietZone: Int = 3

    @State private var matrix: [[Bool]]?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let count = (matrix?.count ?? 0) + quietZone * 2
            let unit = count > 0 ? side / CGFloat(count) : 0
            Canvas { context, _ in
                guard let matrix, unit > 0 else { return }
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: colors),
                    startPoint: .zero,
                    endPoint: CGPoint(x: side, y: side))
                for (y, row) in matrix.enumerated() {
                    for (x, dark) in row.enumerated() where dark {
                        let rect = CGRect(x: CGFloat(x + quietZone) * unit,
                                          y: CGFloat(y + quietZone) * unit,
                                          width: unit,
                                          height: unit)
                            .insetBy(dx: unit * 0.05, dy: unit * 0.05)
                        let path = Path(roundedRect: rect, cornerRadius: unit * 0.30)
                        context.fill(path, with: shading)
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .task(id: text) {
            matrix = QRCodeMatrix.make(text)
        }
    }
}
