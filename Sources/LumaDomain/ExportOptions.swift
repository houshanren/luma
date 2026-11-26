import Foundation
import UniformTypeIdentifiers

public enum ExportImageFormat: String, CaseIterable, Identifiable {
    case original
    case jpeg
    case heic
    case png
    case tiff

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "原格式"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }

    public var fileExtension: String? {
        switch self {
        case .original: return nil
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    public var utType: UTType? {
        switch self {
        case .original: return nil
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        case .tiff: return .tiff
        }
    }

    /// 只有有损格式才需要质量参数。
    public var supportsQuality: Bool {
        self == .jpeg || self == .heic
    }
}

public enum ExportFilenameRule: String, CaseIterable, Identifiable {
    case original
    case title
    case dateSequence
    case sequence

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "原始文件名"
        case .title: return "标题"
        case .dateSequence: return "拍摄日期 + 序号"
        case .sequence: return "序号"
        }
    }

    public var example: String {
        switch self {
        case .original: return "IMG_0001.HEIC"
        case .title: return "西湖日落.jpg"
        case .dateSequence: return "20250318-164500-001.jpg"
        case .sequence: return "IMG-001.jpg"
        }
    }
}

public struct ExportOptions {
    public var format: ExportImageFormat = .original
    /// 仅对 JPEG / HEIC 生效，0.3…1.0。
    public var quality: Double = 0.9
    /// 0 表示保持原始像素尺寸。
    public var maxDimension: Int = 0
    /// 重新编码时是否写入拍摄时间等基础元数据（原始格式导出始终保留完整元数据）。
    public var includeMetadata: Bool = true
    public var filenameRule: ExportFilenameRule = .original
    /// 导出未修改的原片（忽略裁剪、旋转与调色）。
    public var exportOriginal: Bool = false

    public static let maxDimensionChoices: [Int] = [0, 4096, 2048, 1024, 640]

    public static func maxDimensionTitle(_ value: Int) -> String {
        value == 0 ? "原始尺寸" : "最长边 \(value) px"
    }
    public init(
        format: ExportImageFormat = .original,
        quality: Double = 0.9,
        maxDimension: Int = 0,
        includeMetadata: Bool = true,
        filenameRule: ExportFilenameRule = .original,
        exportOriginal: Bool = false
    ) {
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
        self.includeMetadata = includeMetadata
        self.filenameRule = filenameRule
        self.exportOriginal = exportOriginal
    }
}
