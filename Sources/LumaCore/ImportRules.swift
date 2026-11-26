import Foundation

/// 导入候选的媒体类型：与 App 的 `MediaKind` 一一对应，
/// 放在纯逻辑层是为了让分类规则可以脱离 AppKit 单独检查。
public enum ImportedMediaKind: String, Equatable, Sendable {
    case photo
    case video
    case screenshot
    case panorama
    case selfie
}

/// 导入相关的纯规则：文件类型白名单、实况照片配对、媒体类型归类与蓝光失败文案。
/// 不读磁盘、不依赖 AppKit；目录遍历与 ffprobe 仍由 App 侧完成。
public enum ImportRules {
    /// 可导入 / 可播放的视频扩展名。部分容器（mkv/avi/flv/wmv…）系统 UTI 未声明为 movie，
    /// 只能按扩展名识别，因此这份白名单是导入判定的第一依据。
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt",
        "avi", "mkv", "webm", "flv", "f4v", "wmv", "asf",
        "mpg", "mpeg", "m2v", "mpe", "m1v", "vob", "ts", "m2ts", "mts", "mtts",
        "3gp", "3g2", "ogv", "rm", "rmvb", "divx", "dv", "mxf", "amv"
    ]

    /// 需要单独的 RAW 解码路径的扩展名。
    public static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rw2", "raw", "rwl", "pef", "srw", "x3f", "3fr", "fff", "iiq",
        "mef", "mos", "mrw", "erf", "kdc", "dcr", "gpr"
    ]

    public static func isVideoExtension(_ extensionName: String) -> Bool {
        videoExtensions.contains(extensionName.lowercased())
    }

    public static func isRawExtension(_ extensionName: String) -> Bool {
        rawExtensions.contains(extensionName.lowercased())
    }

    /// 实况照片配对：同目录、同主文件名（大小写不敏感）的第一个视频文件。
    /// 候选由调用方按目录顺序给出，这里只负责命名与目录匹配。
    public static func livePhotoCompanion(for imageURL: URL, among candidates: [URL]) -> URL? {
        let directory = imageURL.deletingLastPathComponent().standardizedFileURL
        let stem = imageURL.deletingPathExtension().lastPathComponent.lowercased()
        for candidate in candidates {
            let candidateURL = candidate.standardizedFileURL
            guard candidateURL != imageURL.standardizedFileURL,
                  candidateURL.deletingLastPathComponent() == directory,
                  candidateURL.deletingPathExtension().lastPathComponent.lowercased() == stem
            else { continue }
            return candidate
        }
        return nil
    }

    /// 图片归类：截屏优先，其次超宽画幅全景，再次文件名里的自拍标记，最后普通照片。
    public static func classify(fileName: String, pixelWidth: Int, pixelHeight: Int) -> ImportedMediaKind {
        let lower = fileName.lowercased()
        if lower.contains("screenshot") || lower.contains("screen shot")
            || lower.contains("截屏") || lower.contains("屏幕快照") {
            return .screenshot
        }
        if pixelWidth > 0, pixelHeight > 0,
           CGFloat(pixelWidth) / CGFloat(pixelHeight) >= 2.2 {
            return .panorama
        }
        if lower.contains("selfie") || lower.contains("自拍") {
            return .selfie
        }
        return .photo
    }

    /// 蓝光加密标记：AACS 目录 / BD+ 虚拟机会话优先于 ffprobe 的通用报错。
    public static func blurayEncryptionMessage(hasAACS: Bool, hasBDSVM: Bool) -> String? {
        if hasAACS {
            return "这张蓝光光盘受 AACS 加密保护，无法直接播放。"
                + "请先用 MakeMKV 等工具解密为 MKV，或导入已解密的光盘备份。"
        }
        if hasBDSVM {
            return "这张蓝光光盘受 BD+ 加密保护，无法直接播放。"
                + "请先用 MakeMKV 等工具解密为 MKV，或导入已解密的光盘备份。"
        }
        return nil
    }

    /// 把 ffprobe 的英文报错翻译成用户能照着处理的说明。
    public static func blurayFailureMessage(_ raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("aacs") {
            return "这张蓝光光盘受 AACS 加密保护，无法直接播放。"
                + "请先用 MakeMKV 等工具解密为 MKV，或导入已解密的光盘备份。"
        }
        if text.contains("bd+") || text.contains("bdplus") {
            return "这张蓝光光盘受 BD+ 加密保护，无法直接播放。"
                + "请先用 MakeMKV 等工具解密为 MKV，或导入已解密的光盘备份。"
        }
        if text.contains("blu-ray disc not detected")
            || text.contains("not a blu-ray")
            || text.contains("bluray: no") {
            return "没有找到有效的蓝光结构：需要包含 BDMV 目录的原盘文件，或未加密的 ISO 镜像。"
        }
        if text.contains("no playlist") || text.contains("playlist") && text.contains("empty") {
            return "这张光盘里没有可播放的正片播放列表（可能是花絮盘或结构损坏）。"
        }
        if text.contains("permission denied") || text.contains("operation not permitted") {
            return "没有权限读取这张光盘：请在系统设置 › 隐私与安全性 › 文件与文件夹中允许访问，"
                + "或把原盘复制到可读位置后再导入。"
        }
        let firstLine = raw.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty
            ? "无法读取蓝光原盘：光盘结构不完整或已损坏。"
            : "无法读取蓝光原盘：\(firstLine)"
    }

    /// EXIF 的 `yyyy:MM:dd HH:mm:ss`（不带时区，按相机本地时间解释）。
    public static func parseEXIFDate(_ raw: String?, timeZone: TimeZone = .current) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.date(from: raw)
    }
}
