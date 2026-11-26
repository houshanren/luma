import Foundation

/// 网盘照片的持久化缓存行：EXIF、端侧识别结果、特征向量、查看记录都写在这里。
/// 以 `mountID + path` 为键，远端文件大小变化时整行作废。
public struct CloudAssetCacheRow {
    public var path: String
    public var size: Int64?
    public var remoteModified: Date?
    public var exif: CloudPhotoEXIF?
    public var labels: String?
    public var text: String?
    public var feature: Data?
    public var viewedAt: Date?
    public var metadataAt: Date?
    public var analyzedAt: Date?
    public var peopleAt: Date?
    public init(
        path: String,
        size: Int64? = nil,
        remoteModified: Date? = nil,
        exif: CloudPhotoEXIF? = nil,
        labels: String? = nil,
        text: String? = nil,
        feature: Data? = nil,
        viewedAt: Date? = nil,
        metadataAt: Date? = nil,
        analyzedAt: Date? = nil,
        peopleAt: Date? = nil
    ) {
        self.path = path
        self.size = size
        self.remoteModified = remoteModified
        self.exif = exif
        self.labels = labels
        self.text = text
        self.feature = feature
        self.viewedAt = viewedAt
        self.metadataAt = metadataAt
        self.analyzedAt = analyzedAt
        self.peopleAt = peopleAt
    }
}

/// 派生报告的缓存键：本地 / 系统图库 / 网盘各自独立，互不串结果。
public enum DerivedReportKey {
    public static func local(_ kind: String) -> String { "local|\(kind)" }
    public static func system(_ path: String, _ kind: String) -> String { "system|\(path)|\(kind)" }
    public static func cloud(_ mountID: UUID, _ path: String, _ kind: String) -> String {
        "cloud|\(mountID.uuidString)|\(path)|\(kind)"
    }
    public static func cloudMountPrefix(_ mountID: UUID) -> String { "cloud|\(mountID.uuidString)|" }
    public static func systemPrefix(_ path: String) -> String { "system|\(path)|" }
}
