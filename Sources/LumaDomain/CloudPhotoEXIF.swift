import Foundation

/// 网盘照片的 EXIF / GPS 元数据。
///
/// 网盘文件同样带有 EXIF（拍摄时间、相机、镜头、曝光参数、GPS），
/// 只是需要用 Range 请求读取文件头部（WebDAV / 官方网盘）或直接读挂载文件（SMB）。
/// 这里只解析元数据，不下载原图，也不写回网盘。
public struct CloudPhotoEXIF: Codable {
    public var capturedAt: Date?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: String?
    public var aperture: String?
    public var shutterSpeed: String?
    public var focalLength: String?
    public var latitude: Double?
    public var longitude: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public var isEmpty: Bool {
        capturedAt == nil && make == nil && model == nil && lens == nil
            && iso == nil && aperture == nil && shutterSpeed == nil && focalLength == nil
            && latitude == nil && longitude == nil
    }
    public init(
        capturedAt: Date? = nil,
        make: String? = nil,
        model: String? = nil,
        lens: String? = nil,
        iso: String? = nil,
        aperture: String? = nil,
        shutterSpeed: String? = nil,
        focalLength: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.capturedAt = capturedAt
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.focalLength = focalLength
        self.latitude = latitude
        self.longitude = longitude
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
