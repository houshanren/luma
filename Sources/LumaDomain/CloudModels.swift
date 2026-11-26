import Foundation
import UniformTypeIdentifiers

package enum CloudKind: String, Codable {
    case webdav
    case smb
    case aliyun
    case baidu
    case quark
    case pan115

    package var title: String {
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
    package var supportsWrite: Bool { self == .webdav }

    /// 是否支持在向导里选择接入范围与排除目录（Cookie 模式、SMB 与百度 OAuth）。
    package var supportsAccessScope: Bool {
        self == .smb || self == .aliyun || self == .quark || self == .pan115 || self == .baidu
    }

    /// 需要 OAuth 令牌的官方网盘（夸克使用浏览器 Cookie）。
    package var usesOAuth: Bool { self == .aliyun || self == .baidu }

    /// 走浏览器 Cookie / refresh_token 的网盘：失效时可以原地粘贴新凭据重新登录，
    /// 不用再走「新建挂载」向导，也不会影响已有挂载与接入范围。
    package var supportsInPlaceReauth: Bool {
        self == .quark || self == .pan115 || self == .aliyun
    }

    /// 侧边栏与确认卡片共用的图标。
    package var symbolName: String {
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
    package var brand: CloudBrand? {
        switch self {
        case .webdav, .smb: return nil
        case .aliyun: return .aliyun
        case .baidu: return .baidu
        case .quark: return .quark
        case .pan115: return .pan115
        }
    }

    /// 重新连接时走的向导流程。
    package var wizardFlow: CloudWizardFlow {
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
    package static func detect(from address: String) -> CloudKind? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("smb://") ? .smb : nil
    }
}

/// 网盘账号的鉴权方式：官方 OAuth、浏览器 Cookie / 令牌，或扫码拿到的网页登录令牌。
package enum CloudAuthMode: String, Codable {
    case oauth
    case cookie
    /// 阿里云盘扫码登录：令牌来自网页登录，浏览走网页端接口。
    case webQR
}

/// 面包屑节点。WebDAV 用相对路径，阿里云盘用 file_id，百度网盘用绝对路径。
package struct CloudCrumb: Identifiable, Hashable {
    package let id: String
    package let name: String
    package init(
        id: String,
        name: String
    ) {
        self.id = id
        self.name = name
    }
}

/// 接入范围里的一个目录（Cookie 模式可在向导里多选）。
package struct CloudScopeRoot: Codable, Hashable, Identifiable {
    package var path: String
    package var name: String

    package var id: String { path }
    package init(
        path: String,
        name: String
    ) {
        self.path = path
        self.name = name
    }
}

/// 向导里的目录勾选：额外记录当前浏览路径上的祖先，便于多选时去重。
package struct CloudScopePick: Identifiable, Hashable {
    package var root: CloudScopeRoot
    package var ancestors: [String]

    package var id: String { root.path }
    package init(
        root: CloudScopeRoot,
        ancestors: [String]
    ) {
        self.root = root
        self.ancestors = ancestors
    }
}

/// 一个网络存储挂载点。
package struct CloudMount: Identifiable, Codable, Hashable {
    package var id: UUID = UUID()
    package var kind: CloudKind = .webdav
    package var name: String
    package var baseURL: String = ""
    package var username: String = ""
    package var remoteDriveID: String?
    package var createdAt: Date = Date()
    package var lastPath: String = ""
    /// SMB 专用：是否递归扫描整个共享，而不是按文件夹浏览。
    package var scanAll: Bool = false
    /// WebDAV 专用：是否信任自签名证书（常见于 NAS 的 HTTPS 端口）。
    package var trustSelfSigned: Bool = false
    /// 鉴权方式：默认官方 OAuth；Cookie 模式不需要开发者应用。
    package var authMode: CloudAuthMode = .oauth
    /// 接入范围：为空表示整个网盘；否则只扫描这些目录（Cookie 模式与 SMB 共用）。
    package var scopeRoots: [CloudScopeRoot] = []
    /// 排除目录：始终跳过这些目录（及其子目录）。
    package var excludedRoots: [CloudScopeRoot] = []
    /// 扫码（webQR）接入范围的旧版迁移标记（v2/v3）。已废弃：迁移标记放在挂载
    /// 字段上会被向导注册无条件覆盖，用户重走向导就把它「消耗」掉，迁移被永久
    /// 跳过；范围重置迁移改用图库 settings 的一次性 key 触发。字段仅为旧图库
    /// JSON 解码兼容保留，不再读写。
    package var aliyunWebScopeV2: Bool = false
    package var aliyunWebScopeV3: Bool = false


    package init(from decoder: Decoder) throws {
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
    package init(id: UUID = UUID(), kind: CloudKind = .webdav, name: String,
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
package struct CloudNameRequest: Identifiable {
    package enum Mode {
        case rename(photoID: UUID, current: String)
        case newFolder
    }

    package let id = UUID()
    package let mode: Mode

    package var title: String {
        switch mode {
        case .rename: return "重命名云端项目"
        case .newFolder: return "新建文件夹"
        }
    }

    package var actionTitle: String {
        switch mode {
        case .rename: return "重命名"
        case .newFolder: return "创建"
        }
    }

    package var initialText: String {
        switch mode {
        case .rename(_, let current): return current
        case .newFolder: return ""
        }
    }

    package var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }
    package init(
        mode: Mode
    ) {
        self.mode = mode
    }
}

/// 网盘全盘扫描状态。
package enum CloudScanPhase: Equatable {
    case idle
    case scanning
    case finished(Date)
    case cancelled
    case failed(String)

    package var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

/// 扫描到的目录：在侧边栏里映射成相簿（文件夹 = 相簿）。
package struct CloudScanFolder: Codable, Hashable, Identifiable {
    package var path: String
    package var name: String
    package var parentPath: String
    /// 扫描时父目录列表返回的修改时间：下一轮增量扫描据此判断子树是否变化。
    package var modifiedAt: Date? = nil

    package var id: String { path }
    package init(
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
package struct CloudFolderNode: Identifiable {
    package var path: String
    package var name: String
    package var parentPath: String
    package var photoCount: Int
    package var cover: PhotoItem?
    package var children: [CloudFolderNode]

    package var id: String { path }
    package init(
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
package struct CloudScanRecord: Codable {
    package var path: String
    package var name: String
    package var size: Int64
    package var modifiedAt: Date?
    package var width: Int?
    package var height: Int?
    package var duration: Double?
    package var remoteID: String?
    package var thumbnailURL: String?
    package var isVideo: Bool
    /// 所属目录（用于恢复后按文件夹相簿筛选）。
    package var folderPath: String?
    /// 视频编码（Aliyun list 自带），恢复快照后转封装仍能写对 hvc1 标签。
    package var codec: String?
    /// EXIF 拍摄时间：与远端修改时间分开保存，恢复后时间轴不会被「最近保存」覆盖。
    package var capturedAt: Date? = nil
    /// 加入 / 保存时间（远端修改时间）。
    package var addedAt: Date? = nil
    package init(
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
package struct CloudScanSnapshot: Codable {
    package var savedAt: Date
    package var folderCount: Int
    package var truncated: Bool
    package var records: [CloudScanRecord]
    package var folders: [CloudScanFolder]?
    /// 上一轮是否完整扫完（未触顶、无目录失败、未取消）：只有完整快照才能用于增量扫描。
    package var complete: Bool? = nil
    /// 路径语义版本：老版本 WebDAV 子目录条目只存文件名，快照需要作废重扫。
    package var pathVersion: Int? = nil
    /// 接入范围签名（选中的目录路径集合）：范围变化后旧快照不能再用。
    package var scopeSignature: String? = nil
    package init(
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
package struct CloudEntry: Identifiable, Hashable {
    package let path: String
    package let name: String
    package let isDirectory: Bool
    package let size: Int64
    package let modifiedAt: Date?
    package let contentType: String?

    package var id: String { path }

    /// 服务端缩略图地址（阿里云盘 / 百度网盘提供）。
    package var thumbnailURL: String?
    /// 服务端文件 ID（百度网盘用 fs_id 取直链）。
    package var remoteID: String?
    /// 服务端返回的媒体尺寸与时长（阿里云盘提供）。
    package var pixelWidth: Int?
    package var pixelHeight: Int?
    package var duration: Double?
    /// 服务端标记为受限内容（夸克 risk_type ≠ 0 / ban）：播放与下载接口都会拒绝。
    package var isRestricted = false
    /// 服务端给出的视频编码（如 hevc）：转封装时需要据此写 hvc1 标签。
    package var codecName: String?

    package var isVideo: Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        if let type = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()),
           type.conforms(to: .movie) {
            return true
        }
        return VideoFormats.isVideo(URL(fileURLWithPath: name))
    }

    package var isMedia: Bool {
        if isDirectory { return false }
        if let contentType {
            let lower = contentType.lowercased()
            if lower.hasPrefix("image/") || lower.hasPrefix("video/") { return true }
        }
        return MediaTypeSupport.isSupportedImport(URL(fileURLWithPath: name))
    }
    package init(
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

package struct CloudStreamResource {
    package let url: URL
    package let headers: [String: String]
    /// 官方转码返回的 HLS 播放列表：交给 AVPlayer 直接播放，不能再走 ffmpeg 的按字节读取。
    package var isHLS = false
    package init(
        url: URL,
        headers: [String: String],
        isHLS: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
    }
}
