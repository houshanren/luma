import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runSubtitleChecks() {

    let srtSample = """
    1
    00:00:01,000 --> 00:00:03,500
    第一行
    第二行

    2
    00:00:05.000 --> 00:00:06.000
    <i>斜体</i>

    3
    00:00:04,000 --> 00:00:04,900
    倒序插入
    """
    let srtCues = SubtitleParser.parse(text: srtSample, fileExtension: "srt")
    expectEqual(srtCues.count, 3, "SRT 解析三条")
    expectEqual(srtCues.first?.text ?? "", "第一行\n第二行", "SRT 保留多行正文")
    expectEqual(srtCues.first?.start ?? 0, 1, "SRT 逗号时间戳")
    expect(srtCues.map(\.start) == srtCues.map(\.start).sorted(), "SRT 按起始时间排序")
    expectEqual(SubtitleParser.cue(at: 2, in: srtCues)?.text ?? "", "第一行\n第二行",
                "按时间命中字幕")
    expectEqual(SubtitleParser.cue(at: 5, in: srtCues)?.text ?? "", "斜体", "HTML 标签被剥离")
    expect(SubtitleParser.cue(at: 3.6, in: srtCues) == nil, "字幕间隙返回 nil")
    expect(SubtitleParser.cue(at: 1, in: []) == nil, "空字幕返回 nil")

    let vttSample = """
    WEBVTT

    00:00:00.500 --> 00:00:02.000
    Hello <b>world</b>
    """
    let vttCues = SubtitleParser.parse(text: vttSample, fileExtension: "vtt")
    expectEqual(vttCues.count, 1, "VTT 走同一条解析路径")
    expectEqual(vttCues.first?.start ?? 0, 0.5, "VTT 点号时间戳")
    expectEqual(vttCues.first?.text ?? "", "Hello world", "VTT 标签被剥离")

    let assSample = """
    [Script Info]
    Title: test

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,72,&H00FF0000,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8\\b1\\i1\\fs60\\c&H0000FF&}顶部字幕\\N第二行
    """
    let assCues = SubtitleParser.parse(text: assSample, fileExtension: "ass")
    expectEqual(assCues.count, 1, "ASS 解析一条")
    if let cue = assCues.first {
        expectEqual(cue.text, "顶部字幕\n第二行", "ASS 换行与覆盖标签被清理")
        expectEqual(cue.start, 1, "ASS 起始时间")
        expectEqual(cue.end, 3, "ASS 结束时间")
        expectEqual(cue.style?.alignment, 8, "行内 \\an 覆盖样式")
        expectEqual(cue.style?.bold, true, "行内 \\b 覆盖样式")
        expectEqual(cue.style?.italic, true, "行内 \\i 覆盖样式")
        expectEqual(cue.style?.fontSize, 60, "行内 \\fs 覆盖字号")
        expectClose(CGFloat(cue.style?.fontScale ?? 0), CGFloat(60.0 / 54.0), accuracy: 0.001,
                    "字号按 1080p 基准换算")
        expectEqual(cue.style?.verticalAnchor, 0, "顶部对齐映射到画面顶部")
        expectClose(CGFloat(cue.style?.primaryColor?.blue ?? 0), 1, accuracy: 0.001,
                    "行内颜色按 ASS 的 BGR 解析")
    }

    let assRed = SubtitleColor.parseASS("&HFF0000&")
    expectClose(CGFloat(assRed?.red ?? 0), 1, accuracy: 0.001, "ASS 6 位颜色首字节是红")
    let assAlpha = SubtitleColor.parseASS("&H80FF0000")
    expectClose(CGFloat(assAlpha?.alpha ?? 0), CGFloat(127.0 / 255.0), accuracy: 0.001,
                "ASS 8 位颜色的 alpha 是透明度")
    expect(SubtitleColor.parseASS("red") == nil, "非 ASS 颜色返回 nil")
    let clampedColor = SubtitleColor(red: 2, green: -1, blue: 0.5, alpha: 3)
    expectEqual(clampedColor.red, 1, "颜色通道上限夹到 1")
    expectEqual(clampedColor.green, 0, "颜色通道下限夹到 0")

    let trickySubtitle = URL(fileURLWithPath: "/tmp/a:b'c\\d.srt")
    expectEqual(PlaybackFilters.subtitleBurnFilter(trickySubtitle),
                "subtitles=filename='/tmp/a\\:b\\'c\\\\d.srt'",
                "字幕路径里的冒号 / 单引号 / 反斜杠被转义")

}
