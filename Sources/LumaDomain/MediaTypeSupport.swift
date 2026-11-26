import Foundation
import UniformTypeIdentifiers
import LumaCore
import PlaybackCore

/// 导入与网盘浏览共用的媒体类型判定：白名单优先，UTType 兜底。
/// 放在领域层，让 `CloudModels` 这类纯模型也能判断媒体类型，而不依赖 App 的 `ImportService`。
package enum MediaTypeSupport {
    /// 图片或视频（含 RAW、以及系统 UTI 已声明为 image 的格式）。
    package static func isImageOrVideo(_ url: URL) -> Bool {
        if VideoFormats.isVideo(url) { return true }
        if ImportRules.isRawExtension(url.pathExtension) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// 可导入的媒体：图片 / 视频 / RAW / 蓝光光盘镜像。
    package static func isSupportedImport(_ url: URL) -> Bool {
        if isImageOrVideo(url) { return true }
        return BluraySource.isDiscImage(url)
    }
}
