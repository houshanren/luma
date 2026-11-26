import Foundation

/// EXIF 拍摄时间的唯一解析入口：`yyyy:MM:dd HH:mm:ss`（不带时区，按相机本地时间解释）。
///
/// 导入、系统索引、系统图库三处都要解析同一种字符串。之前各自新建 `DateFormatter`，
/// 而这些调用都在「每张照片一行」的路径上——万张导入就是上万次分配。
/// 这里缓存一份 formatter 复用：
/// `DateFormatter` 自 macOS 10.9 起可跨线程使用，但时区是可变状态，
/// 所以「设置时区 + 解析」一起用锁包住，避免并发调用互相污染。
public enum EXIFDate {
    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    public static func parse(_ raw: String?, timeZone: TimeZone = .current) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if formatter.timeZone != timeZone { formatter.timeZone = timeZone }
        return formatter.date(from: raw)
    }
}
