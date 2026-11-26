import Foundation
import UniformTypeIdentifiers
import LumaCore

/// 集中维护可导入/可播放的视频扩展名。部分容器（mkv/avi/flv/wmv…）系统 UTI 未声明为 movie，
/// 只能按扩展名识别，因此这里以白名单为主、UTType 为辅。
public enum VideoFormats {
    /// 白名单由 `ImportRules` 统一维护：导入判定与测试使用同一份扩展名集合。
    public static let extensions: Set<String> = ImportRules.videoExtensions

    public static func isVideoExtension(_ ext: String) -> Bool {
        ImportRules.isVideoExtension(ext)
    }

    public static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    /// 打开面板允许的文件类型：系统 image/movie 加上每种视频扩展名的 UTI。
    public static var importContentTypes: [UTType] {
        var types: [UTType] = [.image, .movie]
        // 蓝光光盘镜像。
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext), !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }
}
