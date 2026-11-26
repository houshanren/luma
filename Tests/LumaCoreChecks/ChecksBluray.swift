import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runBlurayChecks() {

    let discRoot = URL(fileURLWithPath: "/Volumes/BDMV_DISC")
    let bdmvFile = discRoot.appendingPathComponent("BDMV/STREAM/00001.m2ts")
    expectEqual(BluraySource.discRoot(containing: bdmvFile)?.path, discRoot.path,
                "BDMV 内的 m2ts 折叠成盘根目录")
    expect(BluraySource.discRoot(containing: URL(fileURLWithPath: "/Volumes/Movie.mkv")) == nil,
           "普通视频不当作蓝光")
    let isoURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-check-\(UUID().uuidString).iso")
    FileManager.default.createFile(atPath: isoURL.path, contents: Data())
    expectEqual(BluraySource.ffmpegInput(for: isoURL), "bluray:" + isoURL.path,
                "ISO 生成 bluray 协议输入")
    try? FileManager.default.removeItem(at: isoURL)



    func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// 造一个单播放项的 MPLS：播放项时长 durationTicks（45kHz），带章节标记与角度数。
    func makeMPLS(durationTicks: Int, chapterTicks: [Int], angleCount: Int = 1) -> Data {
        var item: [UInt8] = []
        item += [0x30, 0x30, 0x30, 0x30, 0x30]   // clip name "00000"
        item += [0x4D, 0x32, 0x54, 0x53]         // "M2TS"
        // flags 第 4 位是 multi_angle（位于长度字段之后的第 9、10 字节）。
        item += be16(angleCount > 1 ? 0x0010 : 0)
        item += [0]                               // stc id
        item += be32(0)                           // in_time
        item += be32(durationTicks)               // out_time
        item += [UInt8](repeating: 0, count: 8)   // UO mask
        item += [0, 0]                            // random_access_flag + still_mode
        item += be16(0)                           // still_time
        if angleCount > 1 {
            item += [UInt8(angleCount)]           // angle_count
            item += [0]                           // angle flags
        }

        var playlist: [UInt8] = []
        playlist += be16(0)                       // reserved
        playlist += be16(1)                       // 播放项数
        playlist += be16(0)                       // 子路径数
        playlist += be16(item.count) + item

        var marks: [UInt8] = []
        marks += be16(chapterTicks.count)
        for ticks in chapterTicks {
            marks += be16(0)                      // reserved
            marks += [1]                          // mark type = 章节
            marks += be16(1)                      // 播放项序号（1 起）
            marks += be32(ticks)                  // 时间戳
            marks += be16(0)                      // pid
            marks += be32(0)                      // duration
        }

        let playlistStart = 20
        let markStart = playlistStart + 4 + playlist.count
        var data: [UInt8] = Array("MPLS".utf8) + Array("0200".utf8)
        data += be32(playlistStart)
        data += be32(markStart)
        data += be32(0)
        data += be32(playlist.count) + playlist
        data += be32(marks.count) + marks
        return Data(data)
    }

    let disc = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-bd-\(UUID().uuidString)", isDirectory: true)
    let playlistDirectory = disc.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
    try? FileManager.default.createDirectory(at: playlistDirectory, withIntermediateDirectories: true)
    let minute = 45_000 * 60
    try? makeMPLS(durationTicks: minute * 40, chapterTicks: [0, minute * 10, minute * 25])
        .write(to: playlistDirectory.appendingPathComponent("00000.mpls"))
    let discChapters = BluraySource.chapters(for: disc)
    expectEqual(discChapters.count, 3, "MPLS 章节标记解析出 3 段")
    if discChapters.count == 3 {
        expectClose(CGFloat(discChapters[1].start), 600, accuracy: 1, "第二章起点 10 分钟")
        expectClose(CGFloat(discChapters[2].start), 1500, accuracy: 1, "第三章起点 25 分钟")
        expectClose(CGFloat(discChapters[2].end), 2400, accuracy: 1, "最后一章到片尾")
    }
    try? FileManager.default.removeItem(at: disc)



    let angleDisc = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-bd-angle-\(UUID().uuidString)", isDirectory: true)
    let anglePlaylistDirectory = angleDisc.appendingPathComponent("BDMV/PLAYLIST", isDirectory: true)
    try? FileManager.default.createDirectory(at: anglePlaylistDirectory, withIntermediateDirectories: true)
    try? makeMPLS(durationTicks: minute * 40, chapterTicks: [0, minute * 20], angleCount: 3)
        .write(to: anglePlaylistDirectory.appendingPathComponent("00000.mpls"))
    expectEqual(BluraySource.angleCount(for: angleDisc), 3, "MPLS 多角度数量解析")
    expect(BluraySource.playlistInfo(for: angleDisc)?.chapters.count == 2, "多角度播放列表仍解析章节")
    try? FileManager.default.removeItem(at: angleDisc)

    var angleRequest = baseRequest()
    angleRequest.angle = 2
    let angleJoined = StreamPlanner.arguments(for: angleRequest).joined(separator: " ")
    expect(angleJoined.contains("-angle 2 -i bluray:"), "角度写在 -i 之前（demuxer 输入选项）")
    var fileAngleRequest = baseRequest()
    fileAngleRequest.input = "/tmp/luma-movie.mkv"
    fileAngleRequest.angle = 2
    expect(!StreamPlanner.arguments(for: fileAngleRequest).joined(separator: " ").contains("-angle"),
           "普通文件忽略角度参数")

    expectEqual(SubtitlePreference.rank(language: "zh-cn"), 0, "简体中文最优先")
    expectEqual(SubtitlePreference.rank(language: "chs"), 0, "chs 视为简体中文")
    expectEqual(SubtitlePreference.rank(language: "zh-hant"), 1, "繁体中文次之")
    expectEqual(SubtitlePreference.rank(language: "chi"), 2, "通用中文语言码")
    expectEqual(SubtitlePreference.rank(language: nil, title: "中文字幕"), 2, "轨道名带中文也算中文")
    expectEqual(SubtitlePreference.rank(language: "en"), 4, "英语排在中文之后")
    expectEqual(SubtitlePreference.rank(language: "jpn"), 5, "其他已知语言")
    expectEqual(SubtitlePreference.rank(language: "und"), 6, "未知语言最后")
    expectEqual(SubtitlePreference.bestIndex(languages: ["eng", "zh-tw", "zh-cn"]), 2,
                "自动挂载挑简体中文轨")
    expectEqual(SubtitlePreference.rank(externalFileName: "movie.zh-Hans.srt", baseName: "movie"), 0,
                "外挂字幕简体优先")
    expectEqual(SubtitlePreference.rank(externalFileName: "movie.cht.srt", baseName: "movie"), 1,
                "外挂字幕繁体次之")
    expectEqual(SubtitlePreference.rank(externalFileName: "movie.zh.srt", baseName: "movie"), 2,
                "外挂字幕通用中文")
    expectEqual(SubtitlePreference.rank(externalFileName: "movie.srt", baseName: "movie"), 3,
                "无语言标记的外挂字幕居中")
    expectEqual(SubtitlePreference.rank(externalFileName: "movie.en.srt", baseName: "movie"), 4,
                "外挂英文字幕排在中文之后")
    expectEqual(SubtitlePreference.searchLanguageList, "zh-cn,zh-tw,en",
                "在线字幕按偏好顺序请求语言")

}
