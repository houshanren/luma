import Foundation
import LumaCore
import TestSupport

/// 导入规则：文件类型白名单、实况照片配对、媒体归类、蓝光文案与 EXIF 时间。
/// 这些规则原先埋在 `ImportService` 里，现在由 `ImportRules` 统一提供，App 与测试共用。
func runImportChecks() {
    expect(ImportRules.isVideoExtension("MP4"), "扩展名判定不区分大小写")
    for ext in ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mtts", "rmvb"] {
        expect(ImportRules.isVideoExtension(ext), "视频扩展名 \(ext) 可导入")
    }
    for ext in ["jpg", "heic", "png", "iso", "txt"] {
        expect(!ImportRules.isVideoExtension(ext), "非视频扩展名 \(ext) 不按视频导入")
    }

    expect(ImportRules.isRawExtension("DNG"), "RAW 扩展名判定不区分大小写")
    for ext in ["dng", "nef", "arw", "raf", "orf", "gpr"] {
        expect(ImportRules.isRawExtension(ext), "RAW 扩展名 \(ext) 可导入")
    }
    expect(!ImportRules.isRawExtension("jpg"), "普通图片不算 RAW")

    let directory = URL(fileURLWithPath: "/tmp/LumaImportCheck", isDirectory: true)
    let image = directory.appendingPathComponent("IMG_1234.HEIC")
    let mov = directory.appendingPathComponent("img_1234.MOV")
    let mp4 = directory.appendingPathComponent("IMG_1234.mp4")
    let differentStem = directory.appendingPathComponent("IMG_9999.MOV")
    let otherDirectory = URL(fileURLWithPath: "/tmp/LumaOther/IMG_1234.MOV")

    expectEqual(ImportRules.livePhotoCompanion(for: image, among: [differentStem, mov])?
        .lastPathComponent, "img_1234.MOV", "同目录同主文件名（忽略大小写）配成实况照片")
    expectEqual(ImportRules.livePhotoCompanion(for: image, among: [mp4, mov])?
        .pathExtension, "mp4", "多个候选时取目录顺序中的第一个")
    expect(ImportRules.livePhotoCompanion(for: image, among: [otherDirectory]) == nil,
           "不同目录不配对")
    expect(ImportRules.livePhotoCompanion(for: image, among: [image]) == nil,
           "图片自己不算配对视频")
    expect(ImportRules.livePhotoCompanion(for: image, among: []) == nil, "没有候选时返回 nil")

    expectEqual(ImportRules.classify(fileName: "Screenshot 2024-01-01.png",
                                     pixelWidth: 100, pixelHeight: 100),
                .screenshot, "英文截屏名称")
    expectEqual(ImportRules.classify(fileName: "屏幕快照 2024-01-01.png",
                                     pixelWidth: 100, pixelHeight: 100),
                .screenshot, "中文截屏名称")
    expectEqual(ImportRules.classify(fileName: "IMG_0001.HEIC",
                                     pixelWidth: 2560, pixelHeight: 1080),
                .panorama, "超宽画幅判为全景")
    expectEqual(ImportRules.classify(fileName: "IMG_0002.HEIC",
                                     pixelWidth: 2200, pixelHeight: 1000),
                .panorama, "2.2 比例边界仍算全景")
    expectEqual(ImportRules.classify(fileName: "IMG_0003.HEIC",
                                     pixelWidth: 2199, pixelHeight: 1000),
                .photo, "不足 2.2 比例不算全景")
    expectEqual(ImportRules.classify(fileName: "selfie_01.jpg",
                                     pixelWidth: 1000, pixelHeight: 1000),
                .selfie, "英文自拍名称")
    expectEqual(ImportRules.classify(fileName: "自拍.jpg",
                                     pixelWidth: 1000, pixelHeight: 1000),
                .selfie, "中文自拍名称")
    expectEqual(ImportRules.classify(fileName: "Screenshot selfie.png",
                                     pixelWidth: 2560, pixelHeight: 1000),
                .screenshot, "截屏优先于全景与自拍")
    expectEqual(ImportRules.classify(fileName: "IMG_0004.HEIC",
                                     pixelWidth: 0, pixelHeight: 0),
                .photo, "尺寸未知时不误判全景")

    expect(ImportRules.blurayEncryptionMessage(hasAACS: true, hasBDSVM: false)?.contains("AACS") == true,
           "AACS 目录给出加密说明")
    expect(ImportRules.blurayEncryptionMessage(hasAACS: false, hasBDSVM: true)?.contains("BD+") == true,
           "BD+ 目录给出加密说明")
    expect(ImportRules.blurayEncryptionMessage(hasAACS: true, hasBDSVM: true)?.contains("AACS") == true,
           "AACS 与 BD+ 同时存在时优先 AACS")
    expect(ImportRules.blurayEncryptionMessage(hasAACS: false, hasBDSVM: false) == nil,
           "没有加密标记时返回 nil")

    expect(ImportRules.blurayFailureMessage("AACS decryption failed").contains("AACS 加密"),
           "ffprobe 的 AACS 报错翻译成加密提示")
    expect(ImportRules.blurayFailureMessage("BD+ virtual machine error").contains("BD+ 加密"),
           "ffprobe 的 BD+ 报错翻译成加密提示")
    expect(ImportRules.blurayFailureMessage("Blu-ray disc not detected")
        .contains("没有找到有效的蓝光结构"), "非蓝光目录给出结构提示")
    expect(ImportRules.blurayFailureMessage("no playlist found")
        .contains("没有可播放的正片播放列表"), "缺少播放列表给出明确提示")
    expect(ImportRules.blurayFailureMessage("playlist is empty")
        .contains("没有可播放的正片播放列表"), "空播放列表同样识别")
    expect(ImportRules.blurayFailureMessage("Permission denied")
        .contains("没有权限读取"), "权限错误给出系统设置指引")
    expect(ImportRules.blurayFailureMessage("Unknown failure line\nmore details")
        .contains("Unknown failure line"), "未知错误保留首行细节")
    expect(ImportRules.blurayFailureMessage("").contains("光盘结构不完整"),
           "空错误回退到结构损坏提示")

    let utc = TimeZone(secondsFromGMT: 0)!
    let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!
    let exifText = "2024:05:06 07:08:09"
    let utcDate = ImportRules.parseEXIFDate(exifText, timeZone: utc)
    expect(utcDate != nil, "合法 EXIF 时间可解析")
    if let utcDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                 from: utcDate)
        expectEqual(components.year, 2024, "EXIF 年")
        expectEqual(components.month, 5, "EXIF 月")
        expectEqual(components.day, 6, "EXIF 日")
        expectEqual(components.hour, 7, "EXIF 时")
        expectEqual(components.minute, 8, "EXIF 分")
        expectEqual(components.second, 9, "EXIF 秒")
    }
    if let utcDate, let shanghaiDate = ImportRules.parseEXIFDate(exifText, timeZone: shanghai) {
        expectEqual(utcDate.timeIntervalSince(shanghaiDate), 8 * 3600,
                    "EXIF 时间按指定时区解释")
    }
    expect(ImportRules.parseEXIFDate("2024-05-06 07:08:09") == nil, "非 EXIF 格式返回 nil")
    expect(ImportRules.parseEXIFDate("") == nil, "空字符串返回 nil")
    expect(ImportRules.parseEXIFDate(nil) == nil, "缺失 EXIF 时间返回 nil")
}
