import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS

enum CloudKind: String, Codable {
    case webdav
    case smb
    case aliyun
    case baidu

    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .smb: return "SMB 共享"
        case .aliyun: return "阿里云盘"
        case .baidu: return "百度网盘"
        }
    }

    /// 只有 WebDAV 允许写入；SMB 与官方网盘均为只读。
    var supportsWrite: Bool { self == .webdav }

    /// 需要 OAuth 令牌的官方网盘。
    var usesOAuth: Bool { self == .aliyun || self == .baidu }

    /// 根据用户输入的地址推断接入类型。
    static func detect(from address: String) -> CloudKind? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("smb://") ? .smb : nil
    }
}

/// 面包屑节点。WebDAV 用相对路径，阿里云盘用 file_id，百度网盘用绝对路径。
struct CloudCrumb: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 一个网络存储挂载点。
struct CloudMount: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: CloudKind = .webdav
    var name: String
    var baseURL: String = ""
    var username: String = ""
    var remoteDriveID: String?
    var createdAt: Date = Date()
    var lastPath: String = ""
    /// SMB 专用：是否递归扫描整个共享，而不是按文件夹浏览。
    var scanAll: Bool = false

    init(id: UUID = UUID(), kind: CloudKind = .webdav, name: String,
         baseURL: String = "", username: String = "", remoteDriveID: String? = nil,
         createdAt: Date = Date(), lastPath: String = "", scanAll: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.remoteDriveID = remoteDriveID
        self.createdAt = createdAt
        self.lastPath = lastPath
        self.scanAll = scanAll
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decodeIfPresent(CloudKind.self, forKey: .kind)) ?? .webdav
        name = (try? container.decode(String.self, forKey: .name)) ?? "网络存储"
        baseURL = (try? container.decode(String.self, forKey: .baseURL)) ?? ""
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        remoteDriveID = try? container.decodeIfPresent(String.self, forKey: .remoteDriveID)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastPath = (try? container.decode(String.self, forKey: .lastPath)) ?? ""
        scanAll = (try? container.decodeIfPresent(Bool.self, forKey: .scanAll)) ?? false
    }
}

/// 云端重命名 / 新建文件夹的输入请求。
struct CloudNameRequest: Identifiable {
    enum Mode {
        case rename(photoID: UUID, current: String)
        case newFolder
    }

    let id = UUID()
    let mode: Mode

    var title: String {
        switch mode {
        case .rename: return "重命名云端项目"
        case .newFolder: return "新建文件夹"
        }
    }

    var actionTitle: String {
        switch mode {
        case .rename: return "重命名"
        case .newFolder: return "创建"
        }
    }

    var initialText: String {
        switch mode {
        case .rename(_, let current): return current
        case .newFolder: return ""
        }
    }

    var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }
}

/// WebDAV 目录中的一项。
struct CloudEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let contentType: String?

    var id: String { path }

    /// 服务端缩略图地址（阿里云盘 / 百度网盘提供）。
    var thumbnailURL: String?
    /// 服务端文件 ID（百度网盘用 fs_id 取直链）。
    var remoteID: String?
    /// 服务端返回的媒体尺寸与时长（阿里云盘提供）。
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?

    var isVideo: Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        if let type = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()),
           type.conforms(to: .movie) {
            return true
        }
        return VideoFormats.isVideo(URL(fileURLWithPath: name))
    }

    var isMedia: Bool {
        if isDirectory { return false }
        if let contentType {
            let lower = contentType.lowercased()
            if lower.hasPrefix("image/") || lower.hasPrefix("video/") { return true }
        }
        return ImportService.isSupported(URL(fileURLWithPath: name))
            || VideoFormats.isVideo(URL(fileURLWithPath: name))
    }
}

struct CloudStreamResource {
    let url: URL
    let headers: [String: String]
}

struct CloudThumbnailResult {
    let image: NSImage?
    let size: CGSize?
    let duration: Double?
}
