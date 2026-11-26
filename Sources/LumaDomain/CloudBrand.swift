import Foundation

/// 官方网盘品牌标识。图标资源随 App 内置，模型层只保留品牌枚举。
package enum CloudBrand: String, CaseIterable {
    case aliyun
    case baidu
    case quark
    case pan115

    package var assetName: String { rawValue }

    /// 图标资源缺失时的兜底符号（仅在开发期资源未拷贝时出现）。
    package var fallbackSymbol: String {
        switch self {
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        case .quark: return "square.stack.3d.up.fill"
        case .pan115: return "externaldrive.fill"
        }
    }
}
