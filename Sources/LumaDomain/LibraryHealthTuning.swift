import Foundation
/// 体检阈值：与 UI 状态无关，放在文件级便于在后台任务里直接使用。
public enum LibraryHealthTuning {
    /// 超过这个大小视为「过大视频」。
    public static let largeVideoBytes: Int64 = 300 * 1024 * 1024
    /// 相似连拍分组的余弦相似度门槛（特征向量已归一化，点积即相似度）。
    public static let similarGroupThreshold: Float = 0.90
    /// 同一组的拍摄时间差上限（秒），避免把同场景不同时段的照片归为一组。
    public static let similarGroupWindow: TimeInterval = 600
    /// 「值得重看」：拍摄距今至少这么久，且最近查看距今至少一年（或从未查看）。
    public static let revisitCaptureAge: TimeInterval = 2 * 365 * 24 * 3600
    public static let revisitViewAge: TimeInterval = 365 * 24 * 3600
}
