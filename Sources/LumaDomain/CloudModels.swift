import Foundation
import UniformTypeIdentifiers

public enum CloudKind: String, Codable {
    case webdav
    case smb
    case aliyun
    case baidu
    case quark
    case pan115

    public var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .smb: return "SMB 共享"
        case .aliyun: return "阿里云盘"
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .pan115: return "115 网盘"
        }
    }

    /// 只有 WebDAV 允许写入；SMB 与官方网盘均为只读。
    public var supportsWrite: Bool { self == .webdav }

    /// 是否支持在向导里选择接入范围与排除目录（Cookie 模式、SMB 与百度 OAuth）。
    public var supportsAccessScope: Bool {
        self == .smb || self == .aliyun || self == .quark || self == .pan115 || self == .baidu
    }

    /// 需要 OAuth 令牌的官方网盘（夸克使用浏览器 Cookie）。
    public var usesOAuth: Bool { self == .aliyun || self == .baidu }

    /// 走浏览器 Cookie / refresh_token 的网盘：失效时可以原地粘贴新凭据重新登录，
    /// 不用再走「新建挂载」向导，也不会影响已有挂载与接入范围。
    public var supportsInPlaceReauth: Bool {
        self == .quark || self == .pan115 || self == .aliyun
    }

    /// 侧边栏与确认卡片共用的图标。
    public var symbolName: String {
        switch self {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "network"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        case .quark: return "square.stack.3d.up.fill"
        case .pan115: return "externaldrive.fill"
        }
    }

    /// 官方网盘的品牌图标；WebDAV / SMB 没有对应产品。
    public var brand: CloudBrand? {
        switch self {
        case .webdav, .smb: return nil
        case .aliyun: return .aliyun
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    /// 重新连接时走的向导流程。
    public var wizardFlow: CloudWizardFlow {
        switch self {
        case .webdav: return .webdav
        case .smb: return .smb
        case .aliyun: return .aliyunCookie
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    /// 根据用户输入的地址推断接入类型。
    public static func detect(from address: String) -> CloudKind? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("smb://") ? .smb : nil
    }
}

/// 网盘账号的鉴权方式：官方 OAuth、浏览器 Cookie / 令牌，或扫码拿到的网页登录令牌。
public enum CloudAuthMode: String, Codable {
    case oauth
    case cookie
    /// 阿里云盘扫码登录：令牌来自网页登录，浏览走网页端接口。
    case webQR
}

/// 面包屑节点。WebDAV 用相对路径，阿里云盘用 file_id，百度网盘用绝对路径。
public struct CloudCrumb: Identifiable, Hashable {
    public let id: String
    public let name: String
    public init(
        id: String,
        name: String
    ) {
        self.id = id
        self.name = name
    }
}

/// 接入范围里的一个目录（Cookie 模式可在向导里多选）。
public struct CloudScopeRoot: Codable, Hashable, Identifiable {
    public var path: String
    public var name: String

    public var id: String { path }
    public init(
        path: String,
        name: String
    ) {
        self.path = path
        self.name = name
    }
}

/// 向导里的目录勾选：额外记录当前浏览路径上的祖先，便于多选时去重。
public struct CloudScopePick: Identifiable, Hashable {
    public var root: CloudScopeRoot
    public var ancestors: [String]

    public var id: String { root.path }
    public init(
        root: CloudScopeRoot,
        ancestors: [String]
    ) {
        self.root = root
        self.ancestors = ancestors
    }
}

/// 一个网络存储挂载点。
public struct CloudMount: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var kind: CloudKind = .webdav
    public var name: String
    public var baseURL: String = ""
    public var username: String = ""
    public var remoteDriveID: String?
    public var createdAt: Date = Date()
    public var lastPath: String = ""
    /// SMB 专用：是否递归扫描整个共享，而不是按文件夹浏览。
    public var scanAll: Bool = false
    /// WebDAV 专用：是否信任自签名证书（常见于 NAS 的 HTTPS 端口）。
    public var trustSelfSigned: Bool = false
    /// 鉴权方式：默认官方 OAuth；Cookie 模式不需要开发者应用。
    public var authMode: CloudAuthMode = .oauth
    /// 接入范围：为空表示整个网盘；否则只扫描这些目录（Cookie 模式与 SMB 共用）。
    public var scopeRoots: [CloudScopeRoot] = []
    /// 排除目录：始终跳过这些目录（及其子目录）。
    public var excludedRoots: [CloudScopeRoot] = []
    /// 扫码（webQR）接入范围的旧版迁移标记（v2/v3）。已废弃：迁移标记放在挂载
    /// 字段上会被向导注册无条件覆盖，用户重走向导就把它「消耗」掉，迁移被永久
    /// 跳过；范围重置迁移改用图库 settings 的一次性 key 触发。字段仅为旧图库
    /// JSON 解码兼容保留，不再读写。
    public var aliyunWebScopeV2: Bool = false
    public var aliyunWebScopeV3: Bool = false


    public init(from decoder: Decoder) throws {
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
        trustSelfSigned = (try? container.decodeIfPresent(Bool.self, forKey: .trustSelfSigned)) ?? false
        authMode = (try? container.decodeIfPresent(CloudAuthMode.self, forKey: .authMode)) ?? .oauth
        scopeRoots = (try? container.decodeIfPresent([CloudScopeRoot].self, forKey: .scopeRoots)) ?? []
        excludedRoots = (try? container.decodeIfPresent([CloudScopeRoot].self, forKey: .excludedRoots)) ?? []
        aliyunWebScopeV2 = (try? container.decodeIfPresent(Bool.self, forKey: .aliyunWebScopeV2)) ?? false
        aliyunWebScopeV3 = (try? container.decodeIfPresent(Bool.self, forKey: .aliyunWebScopeV3)) ?? false
    }
    public init(id: UUID = UUID(), kind: CloudKind = .webdav, name: String,
         baseURL: String = "", username: String = "", remoteDriveID: String? = nil,
         createdAt: Date = Date(), lastPath: String = "", scanAll: Bool = false,
         trustSelfSigned: Bool = false, authMode: CloudAuthMode = .oauth,
         scopeRoots: [CloudScopeRoot] = [],
         excludedRoots: [CloudScopeRoot] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.remoteDriveID = remoteDriveID
        self.createdAt = createdAt
        self.lastPath = lastPath
        self.scanAll = scanAll
        self.trustSelfSigned = trustSelfSigned
        self.authMode = authMode
        self.scopeRoots = scopeRoots
        self.excludedRoots = excludedRoots
    }

}

/// 云端重命名 / 新建文件夹的输入请求。
public struct CloudNameRequest: Identifiable {
    public enum Mode {
        case rename(photoID: UUID, current: String)
        case newFolder
    }

    public let id = UUID()
    public let mode: Mode

    public var title: String {
        switch mode {
        case .rename: return "重命名云端项目"
        case .newFolder: return "新建文件夹"
        }
    }

    public var actionTitle: String {
        switch mode {
        case .rename: return "重命名"
        case .newFolder: return "创建"
        }
    }

    public var initialText: String {
        switch mode {
        case .rename(_, let current): return current
        case .newFolder: return ""
        }
    }

    public var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }
    public init(
        mode: Mode
    ) {
        self.mode = mode
    }
}

/// 网盘全盘扫描状态。
public enum CloudScanPhase: Equatable {
    case idle
    case scanning
    case finished(Date)
    case cancelled
    case failed(String)

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

/// 扫描到的目录：在侧边栏里映射成相簿（文件夹 = 相簿）。
public struct CloudScanFolder: Codable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var parentPath: String
    /// 扫描时父目录列表返回的修改时间：下一轮增量扫描据此判断子树是否变化。
    public var modifiedAt: Date? = nil

    public var id: String { path }
    public init(
        path: String,
        name: String,
        parentPath: String,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.modifiedAt = modifiedAt
    }
}

/// 侧边栏「相簿」里的一层文件夹节点：带聚合数量与封面（取最新一张）。
public struct CloudFolderNode: Identifiable {
    public var path: String
    public var name: String
    public var parentPath: String
    public var photoCount: Int
    public var cover: PhotoItem?
    public var children: [CloudFolderNode]

    public var id: String { path }
    public init(
        path: String,
        name: String,
        parentPath: String,
        photoCount: Int,
        cover: PhotoItem? = nil,
        children: [CloudFolderNode]
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.photoCount = photoCount
        self.cover = cover
        self.children = children
    }
}

/// 全盘扫描快照里的一条媒体记录：只存轻量字段，恢复时再换算成 `PhotoItem`。
public struct CloudScanRecord: Codable {
    public var path: String
    public var name: String
    public var size: Int64
    public var modifiedAt: Date?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var remoteID: String?
    public var thumbnailURL: String?
    public var isVideo: Bool
    /// 所属目录（用于恢复后按文件夹相簿筛选）。
    public var folderPath: String?
    /// 视频编码（Aliyun list 自带），恢复快照后转封装仍能写对 hvc1 标签。
    public var codec: String?
    /// EXIF 拍摄时间：与远端修改时间分开保存，恢复后时间轴不会被「最近保存」覆盖。
    public var capturedAt: Date? = nil
    /// 加入 / 保存时间（远端修改时间）。
    public var addedAt: Date? = nil
    public init(
        path: String,
        name: String,
        size: Int64,
        modifiedAt: Date? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        remoteID: String? = nil,
        thumbnailURL: String? = nil,
        isVideo: Bool,
        folderPath: String? = nil,
        codec: String? = nil,
        capturedAt: Date? = nil,
        addedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.width = width
        self.height = height
        self.duration = duration
        self.remoteID = remoteID
        self.thumbnailURL = thumbnailURL
        self.isVideo = isVideo
        self.folderPath = folderPath
        self.codec = codec
        self.capturedAt = capturedAt
        self.addedAt = addedAt
    }
}

/// 某个网盘挂载的全盘扫描结果（落当前图库的 `derived_reports`，重开即可先显示）。
public struct CloudScanSnapshot: Codable {
    public var savedAt: Date
    public var folderCount: Int
    public var truncated: Bool
    public var records: [CloudScanRecord]
    public var folders: [CloudScanFolder]?
    /// 上一轮是否完整扫完（未触顶、无目录失败、未取消）：只有完整快照才能用于增量扫描。
    public var complete: Bool? = nil
    /// 路径语义版本：老版本 WebDAV 子目录条目只存文件名，快照需要作废重扫。
    public var pathVersion: Int? = nil
    /// 接入范围签名（选中的目录路径集合）：范围变化后旧快照不能再用。
    public var scopeSignature: String? = nil
    public init(
        savedAt: Date,
        folderCount: Int,
        truncated: Bool,
        records: [CloudScanRecord],
        folders: [CloudScanFolder]? = nil,
        complete: Bool? = nil,
        pathVersion: Int? = nil,
        scopeSignature: String? = nil
    ) {
        self.savedAt = savedAt
        self.folderCount = folderCount
        self.truncated = truncated
        self.records = records
        self.folders = folders
        self.complete = complete
        self.pathVersion = pathVersion
        self.scopeSignature = scopeSignature
    }
}

/// WebDAV 目录中的一项。
public struct CloudEntry: Identifiable, Hashable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?
    public let contentType: String?

    public var id: String { path }

    /// 服务端缩略图地址（阿里云盘 / 百度网盘提供）。
    public var thumbnailURL: String?
    /// 服务端文件 ID（百度网盘用 fs_id 取直链）。
    public var remoteID: String?
    /// 服务端返回的媒体尺寸与时长（阿里云盘提供）。
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    /// 服务端标记为受限内容（夸克 risk_type ≠ 0 / ban）：播放与下载接口都会拒绝。
    public var isRestricted = false
    /// 服务端给出的视频编码（如 hevc）：转封装时需要据此写 hvc1 标签。
    public var codecName: String?

    public var isVideo: Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        if let type = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()),
           type.conforms(to: .movie) {
            return true
        }
        return VideoFormats.isVideo(URL(fileURLWithPath: name))
    }

    public var isMedia: Bool {
        if isDirectory { return false }
        if let contentType {
            let lower = contentType.lowercased()
            if lower.hasPrefix("image/") || lower.hasPrefix("video/") { return true }
        }
        return MediaTypeSupport.isSupportedImport(URL(fileURLWithPath: name))
    }
    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date? = nil,
        contentType: String? = nil,
        thumbnailURL: String? = nil,
        remoteID: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: Double? = nil,
        isRestricted: Bool = false,
        codecName: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.thumbnailURL = thumbnailURL
        self.remoteID = remoteID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isRestricted = isRestricted
        self.codecName = codecName
    }
}

public struct CloudStreamResource {
    public let url: URL
    public let headers: [String: String]
    /// 官方转码返回的 HLS 播放列表：交给 AVPlayer 直接播放，不能再走 ffmpeg 的按字节读取。
    public var isHLS = false
    public init(
        url: URL,
        headers: [String: String],
        isHLS: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
    }
}
