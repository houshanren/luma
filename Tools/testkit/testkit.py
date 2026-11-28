#!/usr/bin/env python3
"""拾光 Luma 测试集生成与回归工具。

一个入口覆盖四件事：

1. `dataset`：生成可复现的测试集（图片 / 视频 / 网盘 / 影院 / 资源 / 在线影院 / 电视直播）。
2. `screens`：启动应用内 TestKitHarness，逐页截真实产品界面，产出 PNG + 图注清单。
3. `perf`：视频性能基准（起播、转封装、重编码、拖动、AVPlayer 可播性）。
4. `validate` / `regression`：校验测试集与 mock 源，并串起三组 Swift 断言。

默认产物都在 `~/Movies/LumaTestKit`，不写进仓库：

    dataset/      测试集
    screenshots/  产品截图
    reports/      校验 / 性能 / 回归报告

常用命令：

    python3 Tools/testkit/testkit.py dataset
    python3 Tools/testkit/testkit.py serve
    python3 Tools/testkit/testkit.py screens
    python3 Tools/testkit/testkit.py perf
    python3 Tools/testkit/testkit.py regression --with-ui
    python3 Tools/testkit/testkit.py all

只依赖 Python 标准库 + 仓库内置 ffmpeg/ffprobe + swiftc。
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import mock_sources  # noqa: E402  (同目录模块，复用影院条目 / 频道定义)

DEFAULT_OUT = Path.home() / "Movies/LumaTestKit"
FFMPEG_FULL = ROOT / "Vendor/ffmpeg-dv/bin/ffmpeg"
FFPROBE_FULL = ROOT / "Vendor/ffmpeg-dv/bin/ffprobe"
FFMPEG_STATIC = ROOT / "Vendor/ffmpeg/ffmpeg"
FFPROBE_STATIC = ROOT / "Vendor/ffmpeg/ffprobe"
APP_BIN = ROOT / "Luma.app/Contents/MacOS/Luma"

VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".mkv", ".avi", ".ts", ".webm"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".tiff"}


# ---------------------------------------------------------------------------
# 通用
# ---------------------------------------------------------------------------

def log(message: str) -> None:
    print(message, flush=True)


def ffmpeg_bin() -> Path:
    if FFMPEG_FULL.exists():
        return FFMPEG_FULL
    if FFMPEG_STATIC.exists():
        return FFMPEG_STATIC
    raise SystemExit(
        "找不到内置 ffmpeg。先运行 ./build.sh debug 或 Tools/build/make_vendor_runtime.sh 生成 Vendor/ffmpeg-dv。"
    )


def ffprobe_bin() -> Path:
    if FFPROBE_FULL.exists():
        return FFPROBE_FULL
    if FFPROBE_STATIC.exists():
        return FFPROBE_STATIC
    raise SystemExit("找不到内置 ffprobe，请先构建 Vendor 运行时。")


def run(cmd, timeout=None, check=False, cwd=None):
    started = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except FileNotFoundError as error:
        raise SystemExit(f"命令不存在：{cmd[0]}（{error}）")
    except subprocess.TimeoutExpired:
        return 124, "", f"超时（{timeout}s）", time.time() - started
    if check and result.returncode != 0:
        raise RuntimeError(f"命令失败：{' '.join(map(str, cmd))}\n{result.stderr[-1200:]}")
    return result.returncode, result.stdout, result.stderr, time.time() - started


def ffmpeg(args, note: str, timeout: int = 600) -> None:
    cmd = [str(ffmpeg_bin()), "-hide_banner", "-loglevel", "error", "-y", *map(str, args)]
    code, _, err, elapsed = run(cmd, timeout=timeout)
    if code != 0:
        raise RuntimeError(f"{note} 失败（{elapsed:.1f}s）\n{err[-1600:]}")
    log(f"  ✓ {note}  {elapsed:.1f}s")


def ffprobe_json(path: Path) -> dict:
    code, out, err, _ = run([
        str(ffprobe_bin()), "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(path)
    ], timeout=60)
    if code != 0:
        raise RuntimeError(err.strip()[:400] or "ffprobe 失败")
    return json.loads(out)


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# ---------------------------------------------------------------------------
# 图片
# ---------------------------------------------------------------------------

def compile_image_generator(out: Path) -> Path:
    source = HERE / "fixtures/generate_images.swift"
    binary = out / ".bin/luma-fixture-images"
    latest = binary.stat().st_mtime if binary.exists() else 0
    if source.stat().st_mtime <= latest:
        return binary
    ensure_dir(binary.parent)
    log("编译图片素材生成器 …")
    code, _, err, _ = run(["xcrun", "swiftc", "-O", str(source), "-o", str(binary)])
    if code != 0:
        raise SystemExit(f"swiftc 编译失败：\n{err[-2000:]}")
    return binary


def catalog_items_with_meta() -> list:
    palettes = ["spring", "harbor", "city", "amber", "forest"]
    items = []
    for index, item in enumerate(mock_sources.CATALOG_ITEMS):
        type_name = next((row["type_name"] for row in mock_sources.CATEGORY_ROWS
                          if row["type_id"] == item["type"]), "影视")
        items.append({
            "file": f"catalog/posters/poster_{item['id']:03d}.jpg",
            "title": item["title"],
            "subtitle": f"{item['year']} · {type_name}",
            "palette": palettes[index % len(palettes)],
        })
    return items


def write_posters_json(dataset: Path) -> Path:
    meta = ensure_dir(dataset / ".meta")
    path = meta / "posters.json"
    path.write_text(json.dumps({"items": catalog_items_with_meta()}, ensure_ascii=False, indent=2),
                    encoding="utf-8")
    return path


def generate_images(dataset: Path, force: bool = False, photo_count: int = 0) -> None:
    out = dataset.parent
    binary = compile_image_generator(out)
    posters = write_posters_json(dataset)
    log("生成图片素材（EXIF / GPS / 截屏 / 全景 / 模糊 / 海报）…")
    args = [str(binary), "--out", str(dataset), "--posters-json", str(posters)]
    faces = HERE / "fixtures/faces"
    if faces.is_dir() and any(faces.glob("*.png")):
        args += ["--faces-dir", str(faces)]
        log("  使用 fixtures/faces 里的真人素材合成人物")
    if force:
        args.append("--force")
    if photo_count > 0:
        args += ["--photo-count", str(photo_count)]
        log(f"  规模模式：目标 {photo_count} 张照片（2010–2026 按年分相簿）")
    code, stdout, err, _ = run(args, timeout=max(300, photo_count * 2))
    if code != 0:
        raise SystemExit(f"图片素材失败：\n{err[-2000:]}")
    if stdout.strip():
        log("  " + stdout.strip())


# ---------------------------------------------------------------------------
# 视频
# ---------------------------------------------------------------------------

SUBTITLE_SRT = """1
00:00:00,500 --> 00:00:03,000
拾光测试字幕 · 第一句

2
00:00:03,200 --> 00:00:06,000
山海之间，光落在每一帧上。

3
00:00:06,200 --> 00:00:09,000
Luma TestKit · Subtitle Sample
"""

SUBTITLE_ASS = """[Script Info]
Title: Luma TestKit
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,40,40,80,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:03.00,Default,,0,0,0,,拾光测试 ASS 字幕
Dialogue: 0,0:00:03.50,0:00:06.50,Default,,0,0,0,,ASS 会走烧录分支
"""

CHAPTERS_META = """;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=3000
title=开场

[CHAPTER]
TIMEBASE=1/1000
START=3000
END=6000
title=第一幕

[CHAPTER]
TIMEBASE=1/1000
START=6000
END=9000
title=片尾
"""


# 视频画面统一取自照片素材：一家四口 2010–2026 的旅行与日常。
VIDEO_STYLE = "family-2010-2026-v3"
VIDEO_FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
VIDEO_DATES: dict[str, str] = {}

# (照片关键词, 画面角标, 拍摄时间)
VIDEO_CLIPS = [
    ("维多利亚港", "2010.07 香港维多利亚港", "2010-07-18T17:40:00Z"),
    ("塔下樱花", "2014.03 东京塔下樱花", "2014-03-30T10:20:00Z"),
    ("长隆野生动物", "2019.05 广州长隆", "2019-05-01T10:20:00Z"),
    ("迪士尼乐园", "2019.08 上海迪士尼", "2019-08-17T11:30:00Z"),
    ("皇后镇", "2025.01 新西兰皇后镇", "2025-01-20T09:35:00Z"),
    ("九寨沟", "2022.08 四川九寨沟", "2022-08-06T10:40:00Z"),
    ("布达拉宫", "2023.07 西藏布达拉宫", "2023-07-15T15:20:00Z"),
    ("生日会", "2016.01 北京生日会", "2016-01-09T19:40:00Z"),
    ("运动会", "2017.10 学校运动会", "2017-10-20T09:00:00Z"),
    ("歌剧院", "2024.07 悉尼歌剧院", "2024-07-05T17:30:00Z"),
    ("张家界", "2023.10 湖南张家界", "2023-10-02T09:50:00Z"),
    ("迪士尼烟花", "2024.08 迪士尼烟花", "2024-08-10T20:40:00Z"),
    ("威尼斯", "2019.06 威尼斯运河", "2019-06-24T17:50:00Z"),
    ("写作业", "2021.07 周末写作业", "2021-07-10T15:00:00Z"),
    ("全家福", "2026.02 北京全家福", "2026-02-18T18:00:00Z"),
    ("歌剧院", "2024.07 悉尼歌剧院", "2024-07-05T17:30:00Z"),
    ("皇后镇", "2025.01 新西兰皇后镇", "2025-01-20T09:35:00Z"),
]


def find_photo(dataset: Path, keyword: str) -> Path | None:
    photos = sorted((dataset / "photos").rglob("*.jpg"))
    for photo in photos:
        if keyword and keyword in photo.name:
            return photo
    return photos[0] if photos else None


def photo_clip(dataset: Path, keyword: str, caption: str, size: str,
               rate: int, duration: int, extra: str = "") -> tuple[list, str]:
    """用一张旅行照片生成带缓慢横移和地点角标的视频片段。"""
    photo = find_photo(dataset, keyword)
    if photo is None:
        raise SystemExit("缺少照片素材，请先运行图片生成")
    width, height = (int(value) for value in size.split("x"))
    scale_w, scale_h = int(width * 1.12), int(height * 1.12)
    font = max(18, height // 26)
    filters = (f"scale={scale_w}:{scale_h}:force_original_aspect_ratio=increase,"
               f"crop={width}:{height}:(in_w-out_w)*t/{duration}:(in_h-out_h)/2")
    filters += (f",drawtext=fontfile={VIDEO_FONT}:text='{caption}':fontcolor=white@0.92:"
                f"fontsize={font}:box=1:boxcolor=black@0.32:boxborderw={max(8, font // 3)}:"
                f"x={int(width * 0.05)}:y={int(height * 0.80)}")
    if extra:
        filters += "," + extra
    inputs = ["-loop", "1", "-framerate", str(rate), "-t", str(duration), "-i", str(photo)]
    return inputs, filters


def lavfi_audio(duration: int, frequency: int = 440) -> list:
    return ["-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate=48000:duration={duration}"]


def gen_video_file(out: Path, name: str, args: list, note: str,
                   timeout: int = 900, subdir: str = "videos",
                   date: str | None = None, vf: str | None = None) -> Path:
    path = out / subdir / name
    ensure_dir(path.parent)
    if date:
        VIDEO_DATES[path.name] = date
    if path.exists():
        return path
    metadata = ["-metadata", f"creation_time={date}"] if date else []
    filters = ["-vf", vf] if vf else []
    ffmpeg([*args, *filters, *metadata, "-shortest", str(path)], note=note, timeout=timeout)
    return path


def reset_video_outputs(dataset: Path) -> None:
    """画面风格变化后清掉旧的合成视频，避免沿用上一版测试图案。"""
    marker = dataset / ".meta/video-style.json"
    try:
        style = json.loads(marker.read_text(encoding="utf-8")).get("style")
    except Exception:
        style = None
    if style == VIDEO_STYLE:
        return
    for folder in (dataset / "videos", dataset / "live", dataset / "cinema", dataset / "cloud"):
        if not folder.exists():
            continue
        for path in folder.rglob("*"):
            if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS:
                path.unlink()
    shutil.rmtree(dataset / "live/hls", ignore_errors=True)
    ensure_dir(marker.parent)
    marker.write_text(json.dumps({"style": VIDEO_STYLE}, ensure_ascii=False), encoding="utf-8")


def try_generate(label: str, func) -> None:
    """可选样片失败不影响整套测试集，例如当前 ffmpeg 构建缺少某个编码器。"""
    try:
        func()
    except Exception as error:  # noqa: BLE001 - 生成器要尽量产出可用集合
        log(f"  ! 跳过 {label}：{shorten(str(error), 220)}")


def generate_videos(dataset: Path, large: bool = False) -> None:
    out = dataset
    log("生成视频矩阵（编码 / 容器 / HDR / 音轨 / 字幕 / 章节）…")
    reset_video_outputs(dataset)
    videos = ensure_dir(out / "videos")
    common = ["-movflags", "+faststart"]

    def make(name: str, index: int, size: str, rate: int, duration: int,
             note: str, tail: list, *, extra: str = "",
             timeout: int = 900, subdir: str = "videos") -> None:
        keyword, caption, date = VIDEO_CLIPS[index]
        inputs, vf = photo_clip(dataset, keyword, caption, size, rate, duration, extra)
        gen_video_file(out, name, [*inputs, *tail], note,
                       timeout=timeout, subdir=subdir, date=date, vf=vf)

    # 基准 H.264：固定 GOP，方便后面切片 HLS。
    make("h264_aac_1080p24.mp4", 0, "1920x1080", 24, 8,
         "H.264 / AAC / 1080p24 / MP4",
         [*lavfi_audio(8),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
          "-pix_fmt", "yuv420p", "-g", "48", "-keyint_min", "48", "-sc_threshold", "0",
          "-c:a", "aac", "-b:a", "128k", *common])
    make("h264_aac_1080p30.mp4", 1, "1920x1080", 30, 8,
         "H.264 / AAC / 1080p30 / MP4",
         [*lavfi_audio(8, 520),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", *common])
    make("h264_aac_1080p60.mp4", 2, "1920x1080", 60, 6,
         "H.264 / AAC / 1080p60 / MP4",
         [*lavfi_audio(6, 620),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", *common])
    make("hevc_aac_1080p24.mov", 3, "1920x1080", 24, 8,
         "HEVC / AAC / 1080p24 / MOV（hvc1）",
         [*lavfi_audio(8, 330),
          "-c:v", "libx265", "-preset", "veryfast", "-crf", "26",
          "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
          "-x265-params", "log-level=error",
          "-c:a", "aac", "-b:a", "128k"])
    make("hevc10_hdr10_1080p24.mp4", 4, "1920x1080", 24, 6,
         "HEVC 10bit / HDR10 / MP4",
         [*lavfi_audio(6, 380),
          "-c:v", "libx265", "-preset", "veryfast", "-crf", "26",
          "-pix_fmt", "yuv420p10le",
          "-x265-params",
          "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
          ":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
          ":max-cll=1000,400",
          "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
          "-c:a", "aac", "-b:a", "128k", *common])
    make("h264_ac3_1080p.mkv", 5, "1920x1080", 24, 8,
         "H.264 / AC-3 / 1080p / MKV",
         [*lavfi_audio(8, 300),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "ac3", "-b:a", "384k"])
    try_generate("H.264 / DTS / 1080p / MKV", lambda: make(
        "h264_dts_1080p.mkv", 6, "1920x1080", 24, 8,
        "H.264 / DTS / 1080p / MKV",
        [*lavfi_audio(8, 280),
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
         "-c:a", "dts", "-strict", "-2", "-b:a", "768k"]))
    try_generate("MPEG-4 / MP3 / 720p / AVI", lambda: make(
        "h264_mp3_720p.avi", 7, "1280x720", 25, 8,
        "MPEG-4 / MP3 / 720p / AVI",
        [*lavfi_audio(8, 480),
         "-c:v", "mpeg4", "-q:v", "4",
         "-c:a", "libmp3lame", "-b:a", "192k"]))
    make("h264_aac_1080i.ts", 8, "1920x1080", 25, 8,
         "H.264 / AAC / 1080i 隔行 / TS",
         [*lavfi_audio(8, 400),
          "-flags", "+ildct+ilme",
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "128k", "-f", "mpegts"],
         extra="tinterlace=interleave_top")
    make("h264_aac_portrait.mp4", 9, "1080x1920", 30, 6,
         "H.264 / AAC / 竖屏 1080x1920 / MP4",
         [*lavfi_audio(6, 560),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "128k", *common])
    try_generate("H.264 / AAC / 4K30 / MP4", lambda: make(
        "h264_aac_4k30.mp4", 10, "3840x2160", 30, 4,
        "H.264 / AAC / 4K30 / MP4",
        [*lavfi_audio(4, 240),
         "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28", "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "128k", *common], timeout=1200))
    try_generate("HEVC / AAC / 4K60 / MP4", lambda: make(
        "hevc_aac_4k60.mp4", 11, "3840x2160", 60, 2,
        "HEVC / AAC / 4K60 / MP4",
        [*lavfi_audio(2, 220),
         "-c:v", "libx265", "-preset", "ultrafast", "-crf", "32", "-pix_fmt", "yuv420p",
         "-tag:v", "hvc1", "-x265-params", "log-level=error",
         "-c:a", "aac", "-b:a", "128k", *common], timeout=1200))

    # 字幕与多音轨
    subs = ensure_dir(out / ".meta")
    srt = subs / "sample.srt"
    srt.write_text(SUBTITLE_SRT, encoding="utf-8")
    ass = subs / "sample.ass"
    ass.write_text(SUBTITLE_ASS, encoding="utf-8")
    external = videos / "subs_external.mp4"
    if not external.exists():
        shutil.copy2(videos / "h264_aac_1080p24.mp4", external)
        shutil.copy2(srt, videos / "subs_external.srt")
        shutil.copy2(ass, videos / "subs_external.ass")
        VIDEO_DATES[external.name] = VIDEO_CLIPS[0][2]
        log("  ✓ 外挂字幕（SRT / ASS）")

    make("embedded_subs.mkv", 12, "1920x1080", 24, 9,
         "内嵌 SRT 字幕 / MKV",
         [*lavfi_audio(9, 350),
          "-i", str(srt),
          "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "128k", "-c:s", "srt"])
    make("multiaudio.mkv", 13, "1920x1080", 24, 9,
         "双音轨（国语 / 英语）+ 内嵌字幕 / MKV",
         [*lavfi_audio(9, 300), *lavfi_audio(9, 600),
          "-i", str(srt),
          "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-map", "3:s:0",
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "128k", "-c:s", "srt",
          "-metadata:s:a:0", "language=chi", "-metadata:s:a:1", "language=eng",
          "-metadata:s:a:0", "title=国语", "-metadata:s:a:1", "title=English"])

    # 章节
    chapters = subs / "chapters.txt"
    chapters.write_text(CHAPTERS_META, encoding="utf-8")
    make("chapters.mp4", 14, "1920x1080", 24, 9,
         "带章节的 MP4",
         [*lavfi_audio(9, 360),
          "-f", "ffmetadata", "-i", str(chapters),
          "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "2",
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "128k", *common])

    # 实况照片的视频端：与 live/ 下的 JPEG 同名，导入时自动配对。
    make("live/IMG_0100.mov", 15, "1920x1080", 30, 3,
         "实况照片视频端 1",
         [*lavfi_audio(3, 700),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "96k"], subdir="")
    make("live/IMG_0101.mov", 16, "1920x1080", 30, 3,
         "实况照片视频端 2",
         [*lavfi_audio(3, 760),
          "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
          "-c:a", "aac", "-b:a", "96k"], subdir="")

    # 损坏文件：只保留 ftyp 附近的一小段，没有 moov，ffprobe / 解码都应失败。
    broken = videos / "broken.mp4"
    if not broken.exists():
        data = (videos / "h264_aac_1080p24.mp4").read_bytes()
        broken.write_bytes(data[:1024])
        log("  ✓ 截断 MP4（损坏样本）")

    if large:
        make("large_300mb.mp4", 11, "1920x1080", 30, 180,
             "大视频（约 300MB，用于体检 / 大文件回归）",
             [*lavfi_audio(180, 180),
              "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "14M",
              "-maxrate", "14M", "-bufsize", "28M", "-pix_fmt", "yuv420p",
              "-c:a", "aac", "-b:a", "128k", *common], timeout=1800)

    dates_path = subs / "video_dates.json"
    dates_path.write_text(json.dumps(VIDEO_DATES, ensure_ascii=False, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# HLS / 台标 / 电视
# ---------------------------------------------------------------------------

def write_solid_png(path: Path, start: tuple, end: tuple, size: int = 256) -> None:
    rows = []
    for y in range(size):
        row = bytearray([0])
        ratio = y / max(1, size - 1)
        base = tuple(int(start[i] + (end[i] - start[i]) * ratio) for i in range(3))
        for x in range(size):
            # 中间留一条浅色横带，台标在频道墙上更容易区分。
            if size * 0.42 < x < size * 0.58:
                pixel = (min(255, base[0] + 60), min(255, base[1] + 60), min(255, base[2] + 60))
            else:
                pixel = base
            row.extend(pixel)
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (len(data).to_bytes(4, "big") + kind + data
                + zlib.crc32(kind + data).to_bytes(4, "big"))

    header = (b"\x89PNG\r\n\x1a\n"
              + chunk(b"IHDR", size.to_bytes(4, "big") * 2 + bytes([8, 2, 0, 0, 0]))
              + chunk(b"IDAT", zlib.compress(raw, 9))
              + chunk(b"IEND", b""))
    path.write_bytes(header)


def generate_live(dataset: Path) -> None:
    log("生成电视直播素材（HLS / 台标 / M3U / EPG）…")
    live = ensure_dir(dataset / "live")
    hls_root = ensure_dir(live / "hls")
    logos = ensure_dir(live / "logos")
    source = dataset / "videos/h264_aac_1080p24.mp4"
    if not source.exists():
        raise SystemExit("缺少基准视频，请先运行 dataset")

    colors = [((34, 92, 160), (16, 40, 90)), ((176, 58, 72), (90, 20, 40)),
              ((36, 128, 96), (12, 60, 48)), ((150, 96, 40), (72, 40, 18))]
    for index in range(4):
        channel = f"channel{index + 1}"
        target = ensure_dir(hls_root / channel)
        playlist = target / "index.m3u8"
        if playlist.exists():
            continue
        ffmpeg(["-stream_loop", "-1", "-i", str(source), "-t", "12",
                "-c", "copy", "-f", "hls",
                "-hls_time", "2", "-hls_list_size", "5",
                "-hls_flags", "independent_segments+delete_segments",
                "-hls_segment_filename", str(target / "seg_%03d.ts"),
                str(playlist)],
               note=f"HLS {channel}")
        # 测试集里的 HLS 是有限片段；去掉 ENDLIST，让客户端按「直播」处理，
        # 否则电视模块的健康探测会把所有频道判成点播 / 失效。
        text = playlist.read_text(encoding="utf-8")
        playlist.write_text(text.replace("#EXT-X-ENDLIST", ""), encoding="utf-8")
    for index, channel in enumerate(mock_sources.TV_CHANNELS):
        path = logos / f"{channel['logo']}.png"
        if path.exists():
            continue
        start, end = colors[index % len(colors)]
        write_solid_png(path, start, end)
    log(f"  ✓ {len(mock_sources.TV_CHANNELS)} 个台标")

    # 静态一份（占位 base），运行时由 mock_sources.py 覆盖成真实端口。
    runtime = ensure_dir(live)
    (runtime / "playlist.static.m3u").write_text("#EXTM3U\n# 由 mock_sources.py 生成运行时 M3U\n",
                                                encoding="utf-8")
    epg_static = live / "epg.static.xml"
    if not epg_static.exists():
        epg_static.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<tv></tv>\n', encoding="utf-8")


# ---------------------------------------------------------------------------
# 影院 / 网盘
# ---------------------------------------------------------------------------

def movie_nfo(title: str, year: str, plot: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>{title}</title>
  <originaltitle>{title}</originaltitle>
  <year>{year}</year>
  <plot>{plot}</plot>
  <genre>剧情</genre>
  <rating>7.8</rating>
  <studio>Luma TestKit</studio>
</movie>
"""


def tvshow_nfo(title: str, year: str, plot: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
  <title>{title}</title>
  <year>{year}</year>
  <plot>{plot}</plot>
  <genre>剧集</genre>
  <rating>8.2</rating>
  <studio>Luma TestKit</studio>
</tvshow>
"""


def generate_cinema(dataset: Path) -> None:
    log("生成影院素材（本地电影 / 剧集 / NFO / 海报）…")
    cinema = ensure_dir(dataset / "cinema")
    movies = ensure_dir(cinema / "Movies")
    shows = ensure_dir(cinema / "TV")
    source = dataset / "videos/h264_aac_1080p24.mp4"
    if not source.exists():
        raise SystemExit("缺少基准视频，请先运行 dataset")

    movie_specs = [
        ("春日序曲 (2025)", "春日序曲", "2025", "101"),
        ("海边来信 (2024)", "海边来信", "2024", "102"),
        ("城市漫游 (2026)", "城市漫游", "2026", "103"),
    ]
    for folder, title, year, poster_id in movie_specs:
        target = ensure_dir(movies / folder)
        video = target / f"{title} ({year}).mp4"
        if not video.exists():
            shutil.copy2(source, video)
        (target / f"{title} ({year}).nfo").write_text(
            movie_nfo(title, year, f"{title} 是拾光测试集里的本地影院样本。"), encoding="utf-8")
        poster_src = dataset / "catalog/posters" / f"poster_{poster_id}.jpg"
        fanart_src = dataset / "catalog/fanart" / f"poster_{poster_id}_fanart.jpg"
        if poster_src.exists():
            shutil.copy2(poster_src, target / "poster.jpg")
        if fanart_src.exists():
            shutil.copy2(fanart_src, target / "fanart.jpg")

    show = ensure_dir(shows / "拾光公寓")
    (show / "tvshow.nfo").write_text(
        tvshow_nfo("拾光公寓", "2026", "一栋公寓里，六个人与六段被拾起的光。"), encoding="utf-8")
    season = ensure_dir(show / "Season 01")
    for episode in range(1, 4):
        target = season / f"拾光公寓 S01E{episode:02d}.mp4"
        if not target.exists():
            shutil.copy2(source, target)
    poster_src = dataset / "catalog/posters/poster_201.jpg"
    fanart_src = dataset / "catalog/fanart/poster_201_fanart.jpg"
    if poster_src.exists():
        shutil.copy2(poster_src, show / "poster.jpg")
    if fanart_src.exists():
        shutil.copy2(fanart_src, show / "fanart.jpg")


def generate_cloud(dataset: Path) -> None:
    log("生成网盘 / NAS 素材（目录树 / 相簿 / 大文件）…")
    cloud = ensure_dir(dataset / "cloud")
    photo_dirs = sorted((dataset / "photos").glob("*")) if (dataset / "photos").exists() else []
    video_dir = dataset / "videos"
    if not photo_dirs:
        raise SystemExit("缺少图片素材，请先运行 dataset")

    for index, source_dir in enumerate(photo_dirs):
        target = ensure_dir(cloud / "照片" / source_dir.name)
        for file in sorted(source_dir.glob("*.jpg"))[:5]:
            if not (target / file.name).exists():
                shutil.copy2(file, target / file.name)

    target = ensure_dir(cloud / "相簿" / "NAS 收藏")
    picks = []
    for source_dir in photo_dirs:
        picks.extend(sorted(source_dir.glob("*.jpg"))[:2])
    for file in picks[:6]:
        if not (target / file.name).exists():
            shutil.copy2(file, target / file.name)

    video_target = ensure_dir(cloud / "视频" / "春日序曲 (2025)")
    for name in ("h264_aac_1080p24.mp4",):
        source = video_dir / name
        if source.exists() and not (video_target / name).exists():
            shutil.copy2(source, video_target / name)
    movie_posters = dataset / "catalog/posters"
    if (movie_posters / "poster_101.jpg").exists():
        shutil.copy2(movie_posters / "poster_101.jpg", video_target / "poster.jpg")
    (video_target / "movie.nfo").write_text(
        movie_nfo("春日序曲", "2025", "网盘影院里的本地 NFO 样本。"), encoding="utf-8")

    (cloud / "README.txt").write_text(
        "Luma 测试集 · 网盘目录\n"
        "用 Tools/testkit/testkit.py serve 启动 WebDAV 后，\n"
        "把 http://127.0.0.1:<port>/webdav 接入「网络存储」即可浏览。\n",
        encoding="utf-8")


# ---------------------------------------------------------------------------
# 清单
# ---------------------------------------------------------------------------

def build_manifest(dataset: Path) -> dict:
    photos = sorted((dataset / "photos").rglob("*.jpg"))
    screenshots = sorted((dataset / "screenshots").glob("*.png"))
    videos = sorted([p for p in (dataset / "videos").rglob("*")
                     if p.suffix.lower() in VIDEO_EXTENSIONS])
    cinema = sorted((dataset / "cinema").rglob("*"))
    cloud = sorted((dataset / "cloud").rglob("*"))
    hls = sorted((dataset / "live/hls").glob("*/index.m3u8"))
    manifest = {
        "schemaVersion": 1,
        "generatedAt": now_iso(),
        "root": str(dataset),
        "modules": {
            "photos": {"count": len(photos), "albums": sorted({p.parent.name for p in photos})},
            "screenshots": {"count": len(screenshots)},
            "videos": {
                "count": len(videos),
                "files": [p.name for p in videos],
            },
            "cinema": {"count": len([p for p in cinema if p.is_file()])},
            "cloud": {"count": len([p for p in cloud if p.is_file()])},
            "catalog": {
                "items": len(mock_sources.CATALOG_ITEMS),
                "posters": len(list((dataset / "catalog/posters").glob("*.jpg"))),
            },
            "tv": {
                "channels": len(mock_sources.TV_CHANNELS),
                "hlsStreams": len(hls),
            },
        },
        "entryPoints": {
            "serve": "python3 Tools/testkit/testkit.py serve",
            "screens": "python3 Tools/testkit/testkit.py screens",
            "perf": "python3 Tools/testkit/testkit.py perf",
            "validate": "python3 Tools/testkit/testkit.py validate",
            "harnessEnv": "LUMA_TESTKIT_DATASET / LUMA_TESTKIT_SEED / LUMA_TESTKIT_SCREEN",
        },
    }
    (dataset / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return manifest


# ---------------------------------------------------------------------------
# dataset 命令
# ---------------------------------------------------------------------------

def cmd_dataset(out: Path, large: bool = False, force: bool = False, photos: int = 0) -> None:
    dataset = ensure_dir(out / "dataset")
    ensure_dir(out / "reports")
    log(f"测试集输出：{dataset}")
    generate_images(dataset, force=force, photo_count=photos)
    generate_videos(dataset, large=large)
    generate_live(dataset)
    generate_cinema(dataset)
    generate_cloud(dataset)
    manifest = build_manifest(dataset)
    log("测试集完成："
        f"{manifest['modules']['photos']['count']} 照片 / "
        f"{manifest['modules']['videos']['count']} 视频 / "
        f"{manifest['modules']['catalog']['items']} 影院条目 / "
        f"{manifest['modules']['tv']['channels']} 电视频道")
    log(f"清单：{dataset / 'manifest.json'}")


# ---------------------------------------------------------------------------
# validate 命令
# ---------------------------------------------------------------------------

def shorten(text: str, limit: int = 300) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + "…"


def validate_dataset(dataset: Path, self_test_server: bool = True) -> dict:
    errors = []
    warnings = []
    checks = []

    if not dataset.exists():
        return {"ok": False, "errors": [f"测试集不存在：{dataset}"], "warnings": [], "checks": []}

    photos = sorted((dataset / "photos").rglob("*.jpg"))
    if len(photos) < 20:
        errors.append(f"照片数量不足：{len(photos)}")
    else:
        checks.append(f"照片 {len(photos)} 张")
    # 抽样校验 EXIF 日期 / GPS 与损坏文件
    sample = photos[0] if photos else None
    if sample:
        code, out, _, _ = run(["sips", "-g", "creation", "-g", "make", "-g", "model", str(sample)])
        if code != 0 or "creation:" not in out:
            errors.append("抽样照片缺少 EXIF 拍摄时间")
        else:
            checks.append("照片 EXIF 正常")
    gps_photo = next((p for p in photos if "九寨沟" in p.name), None)
    if gps_photo:
        code, out, _, _ = run(["xcrun", "swift", "-e", f'''
import ImageIO
import Foundation
let url = URL(fileURLWithPath: "{gps_photo}")
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
print(props["{{GPS}}"] != nil ? "gps-ok" : "gps-missing")
'''], timeout=120)
        if code != 0 or "gps-ok" not in out:
            warnings.append("抽样照片没有读到 GPS")
        else:
            checks.append("照片 GPS 正常")

    videos = sorted([p for p in (dataset / "videos").rglob("*")
                     if p.suffix.lower() in VIDEO_EXTENSIONS])
    if len(videos) < 10:
        errors.append(f"视频数量不足：{len(videos)}")
    for video in videos:
        if video.name == "broken.mp4":
            try:
                ffprobe_json(video)
                errors.append("损坏样本 broken.mp4 竟然能被 ffprobe 解析")
            except Exception:
                checks.append("损坏样本按预期失败")
            continue
        try:
            info = ffprobe_json(video)
            duration = float(info.get("format", {}).get("duration", 0))
            if duration <= 0:
                errors.append(f"{video.name} 时长为 0")
        except Exception as error:
            errors.append(f"{video.name} ffprobe 失败：{shorten(str(error), 120)}")
    if videos:
        checks.append(f"视频 {len(videos)} 个可解析")
    dates_file = dataset / ".meta/video_dates.json"
    if not dates_file.exists():
        warnings.append("缺少 video_dates.json，视频时间将由文件创建时间决定")
    else:
        checks.append("视频日期清单存在")

    # HLS
    playlists = sorted((dataset / "live/hls").glob("*/index.m3u8"))
    if len(playlists) < 4:
        errors.append(f"HLS 切片不足：{len(playlists)}")
    for playlist in playlists:
        segments = list(playlist.parent.glob("*.ts"))
        if not segments:
            errors.append(f"{playlist.parent.name} 没有 TS 切片")
    if playlists:
        checks.append(f"HLS {len(playlists)} 路")

    # 影院 / 网盘
    movies = list((dataset / "cinema/Movies").glob("*/**/*.nfo"))
    if len(movies) < 3:
        errors.append(f"影院 NFO 不足：{len(movies)}")
    else:
        checks.append(f"影院 NFO {len(movies)} 个")
    if not (dataset / "cloud/照片").exists():
        errors.append("网盘目录树缺失")
    else:
        checks.append("网盘目录树存在")

    # 海报
    posters = list((dataset / "catalog/posters").glob("*.jpg"))
    if len(posters) < len(mock_sources.CATALOG_ITEMS):
        errors.append(f"影院海报不足：{len(posters)}")
    else:
        checks.append(f"海报 {len(posters)} 张")

    # M3U / EPG 静态检查
    sys.path.insert(0, str(HERE))
    mock_sources.STATE.dataset = dataset
    mock_sources.STATE.host = "127.0.0.1"
    mock_sources.STATE.port = 9
    m3u_text = mock_sources.build_m3u()
    if "#EXTINF" not in m3u_text or "tvg-id" not in m3u_text:
        errors.append("M3U 生成异常")
    else:
        checks.append("M3U 多线路正常")
    try:
        ET.fromstring(mock_sources.build_epg())
        checks.append("EPG XML 正常")
    except ET.ParseError as error:
        errors.append(f"EPG XML 解析失败：{error}")

    # mock 源自检
    if self_test_server:
        port = free_port()
        mock_sources.STATE.dataset = dataset
        mock_sources.STATE.host = "127.0.0.1"
        mock_sources.STATE.port = port
        server = mock_sources.Server(("127.0.0.1", port), mock_sources.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{port}"
        try:
            if _http_json(base + "/health").get("ok"):
                checks.append("mock 服务 /health 正常")
            else:
                errors.append("mock /health 返回异常")
        except Exception as error:
            errors.append(f"mock /health 失败：{error}")
        try:
            health = _http_json(base + "/cms/api.php/provide/vod/?ac=list")
            if not health.get("class"):
                errors.append("苹果CMS /ac=list 没有分类")
            else:
                checks.append("苹果CMS 分类接口正常")
            detail = _http_json(base + "/cms/api.php/provide/vod/?ac=detail&ids=101")
            if not detail.get("list"):
                errors.append("苹果CMS /ac=detail&ids=101 没有条目")
            else:
                checks.append("苹果CMS 详情接口正常")
        except Exception as error:
            errors.append(f"苹果CMS 接口失败：{error}")
        try:
            request = urllib.request.Request(base + "/webdav/", method="PROPFIND",
                                             headers={"Depth": "1", "Content-Type": "application/xml"})
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read().decode("utf-8", "replace")
                if response.status != 207 or "<D:href>" not in body:
                    errors.append("WebDAV PROPFIND 返回异常")
                else:
                    checks.append("WebDAV PROPFIND 正常")
            video = next((dataset / "cloud/视频").rglob("*.mp4"), None)
            if video:
                relative = video.relative_to(dataset / "cloud").as_posix()
                url = base + "/webdav/" + urllib.parse.quote(relative)
                request = urllib.request.Request(url, headers={"Range": "bytes=0-1023"})
                with urllib.request.urlopen(request, timeout=10) as response:
                    if response.status != 206 or len(response.read()) != 1024:
                        errors.append("WebDAV Range 返回异常")
                    else:
                        checks.append("WebDAV Range 正常")
        except Exception as error:
            errors.append(f"WebDAV 自检失败：{error}")
        try:
            with urllib.request.urlopen(base + "/epg.xml", timeout=10) as response:
                ET.fromstring(response.read())
                checks.append("EPG 可访问")
        except Exception as error:
            errors.append(f"EPG 访问失败：{error}")
        try:
            with urllib.request.urlopen(base + "/", timeout=10) as response:
                home = response.read().decode("utf-8", "replace")
            if "/file/" not in home:
                errors.append("图集站首页没有条目卡片")
            else:
                checks.append("图集站首页正常")
            with urllib.request.urlopen(base + "/file/seaside-morning/", timeout=10) as response:
                detail = response.read().decode("utf-8", "replace")
            if "data-photo-num" not in detail:
                errors.append("图集详情页没有图片")
            else:
                checks.append("图集详情正常")
            with urllib.request.urlopen(base + "/all-tags", timeout=10) as response:
                tags = response.read().decode("utf-8", "replace")
            if "tag-name" not in tags:
                errors.append("图集标签墙为空")
            else:
                checks.append("图集标签墙正常")
        except Exception as error:
            errors.append(f"图集站自检失败：{error}")
        finally:
            server.shutdown()
            server.server_close()

    return {"ok": not errors, "errors": errors, "warnings": warnings,
            "checks": checks, "generatedAt": now_iso()}


def _http_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def cmd_validate(out: Path) -> int:
    dataset = out / "dataset"
    result = validate_dataset(dataset)
    report_dir = ensure_dir(out / "reports")
    (report_dir / "validation.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    for item in result["checks"]:
        log(f"  ✓ {item}")
    for item in result["warnings"]:
        log(f"  ! {item}")
    for item in result["errors"]:
        log(f"  ✗ {item}")
    log(f"校验{'通过' if result['ok'] else '失败'}：{report_dir / 'validation.json'}")
    return 0 if result["ok"] else 1


# ---------------------------------------------------------------------------
# serve 命令
# ---------------------------------------------------------------------------

def cmd_serve(dataset: Path, port: int, host: str) -> int:
    if not dataset.exists():
        log("测试集不存在，先生成：python3 Tools/testkit/testkit.py dataset")
        return 1
    cmd = [sys.executable, str(HERE / "mock_sources.py"),
           "--dataset", str(dataset), "--port", str(port), "--host", host]
    log("启动 mock 源服务（Ctrl+C 结束）：")
    process = subprocess.Popen(cmd)
    try:
        return process.wait()
    except KeyboardInterrupt:
        process.terminate()
        return 0


# ---------------------------------------------------------------------------
# screens 命令
# ---------------------------------------------------------------------------

def wait_health(base: str, timeout: float = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/health", timeout=2) as response:
                if response.status == 200:
                    return True
        except Exception:
            time.sleep(0.3)
    return False


def luma_running() -> bool:
    code, out, _, _ = run(["pgrep", "-x", "Luma"])
    return code == 0 and bool(out.strip())


def read_screens_catalog() -> list:
    path = HERE / "screens/screens.json"
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("screens", [])
    except Exception:
        return []


def cmd_screens(out: Path, screens: str, build: bool = False,
                settle: float = 2.5, size: str = "1440x900",
                modules: bool = True, port: int = 0,
                app_bin: Path = APP_BIN, skip_running_check: bool = False,
                fresh: bool = True) -> int:
    dataset = out / "dataset"
    shots = ensure_dir(out / "screenshots")
    reports = ensure_dir(out / "reports")
    if not dataset.exists():
        log("测试集不存在，先运行 dataset")
        return 1
    if build:
        code, _, err, _ = run(["./build.sh", "debug"], timeout=1800, cwd=ROOT)
        if code != 0:
            log(f"构建失败：\n{err[-2000:]}")
            return code
    if not app_bin.exists():
        log(f"找不到 {app_bin}，先运行 ./build.sh debug 或加 --build")
        return 1
    if not skip_running_check and luma_running():
        log("Luma 正在运行：应用是单实例，请先退出已打开的 Luma 再截图。")
        return 1

    port = port or free_port()
    server_cmd = [sys.executable, str(HERE / "mock_sources.py"),
                  "--dataset", str(dataset), "--port", str(port)]
    server_log = (reports / "mock-server.log").open("w", encoding="utf-8")
    server = subprocess.Popen(server_cmd, stdout=server_log, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    if not wait_health(base):
        server.terminate()
        log("mock 源服务启动失败，见 reports/mock-server.log")
        return 1

    env = os.environ.copy()
    env.update({
        "LUMA_TESTKIT_DATASET": str(dataset),
        "LUMA_TESTKIT_SHOTS": str(shots),
        "LUMA_TESTKIT_SEED": "1",
        "LUMA_TESTKIT_MODULES": "1" if modules else "0",
        "LUMA_TESTKIT_SERVER": base,
        "LUMA_TESTKIT_TV_PLAYLIST": str(dataset / "live/playlist.runtime.m3u"),
        "LUMA_TESTKIT_SCREEN": screens,
        "LUMA_TESTKIT_SCREENS": str(HERE / "screens/screens.json"),
        # 本机导出的来源配置：网络资源 / 网络影院 / 网络电视，演示库启动时直接导入。
        "LUMA_TESTKIT_SOURCE_BUNDLE": str(ROOT / "StreamSource"),
        # 侧边栏逐层展开：截图里始终是一棵展开的树，新增条目也能被逐项点到。
        "LUMA_TESTKIT_SIDEBAR_EXPAND": "1",
        "LUMA_TESTKIT_SETTLE": str(settle),
        "LUMA_TESTKIT_SIZE": size,
        "LUMA_TESTKIT_QUIT": "1",
        "LUMA_TESTKIT_LIBRARY": str(out / "Demo.photoslibrary"),
        "LUMA_TESTKIT_FRESH": "1" if fresh else "0",
    })
    app_log_path = reports / "app-screens.log"
    # 上一次运行的清单不能冒充这一次的结果。
    index_path = shots / "index.json"
    try:
        index_path.unlink()
    except FileNotFoundError:
        pass
    log(f"启动应用截图：screens={screens}  输出={shots}")
    app_log = app_log_path.open("w", encoding="utf-8")
    process = subprocess.Popen([str(app_bin)], env=env, stdout=app_log, stderr=subprocess.STDOUT)
    started = time.time()
    timeout = 1800 if screens == "all" else 600
    try:
        while process.poll() is None:
            if time.time() - started > timeout:
                process.terminate()
                time.sleep(1)
                if process.poll() is None:
                    process.kill()
                log(f"截图超时（{timeout}s），已结束应用。见 {app_log_path}")
                return 1
            time.sleep(1)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        server_log.close()
        app_log.close()

    if not index_path.exists() or index_path.stat().st_mtime < started:
        log(f"没有生成新的截图清单：{index_path}。日志：{app_log_path}")
        return 1
    index = json.loads(index_path.read_text(encoding="utf-8"))
    captured = index.get("screens", [])
    missing = [item["id"] for item in captured
               if not (shots / item.get("file", "")).exists()]
    summary = {
        "generatedAt": now_iso(),
        "requested": screens,
        "captured": len(captured),
        "missing": missing,
        "shots": str(shots),
        "catalog": read_screens_catalog(),
    }
    (reports / "screens-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    log(f"截图完成 {len(captured)} 张：{shots}")
    log(f"图注清单：{shots / 'captures.md'}")
    if missing:
        log(f"缺少文件：{', '.join(missing)}")
        return 1
    return 0


# ---------------------------------------------------------------------------
# perf 命令
# ---------------------------------------------------------------------------

def avplayer_probe_files(files: list, out_root: Path) -> dict:
    source = ROOT / "Tools/dev/avplayer_probe.swift"
    binary = out_root / ".bin/avprobe"
    if not source.exists():
        return {}
    if not binary.exists() or source.stat().st_mtime > binary.stat().st_mtime:
        ensure_dir(binary.parent)
        code, _, err, _ = run(["xcrun", "swiftc", "-O", "-parse-as-library",
                               str(source), "-o", str(binary)], timeout=600)
        if code != 0:
            log(f"  ! avprobe 编译失败，跳过 AVPlayer 探测：{shorten(err, 200)}")
            return {}
    code, out, err, _ = run([str(binary), *map(str, files)], timeout=600)
    if code != 0:
        log(f"  ! AVPlayer 探测失败：{shorten(err, 200)}")
        return {}
    try:
        rows = json.loads(out)
    except Exception:
        return {}
    return {Path(row.get("input", "")).name: row for row in rows}


def cmd_perf(out: Path, quick: bool = False, include_avplayer: bool = True) -> int:
    dataset = out / "dataset"
    reports = ensure_dir(out / "reports")
    perf_dir = ensure_dir(out / "perf")
    if not dataset.exists():
        log("测试集不存在，先运行 dataset")
        return 1
    videos = sorted([p for p in (dataset / "videos").glob("*")
                     if p.suffix.lower() in VIDEO_EXTENSIONS and p.name != "broken.mp4"])
    if quick:
        videos = [p for p in videos if p.stat().st_size < 30 * 1024 * 1024]
    log(f"视频性能基准：{len(videos)} 个文件")

    results = []
    for video in videos:
        name = video.name
        log(f"- {name}")
        entry = {"file": name, "path": str(video), "sizeBytes": video.stat().st_size}
        try:
            info = ffprobe_json(video)
            entry["duration"] = float(info.get("format", {}).get("duration", 0))
            entry["bitRate"] = int(info.get("format", {}).get("bit_rate", 0) or 0)
            streams = info.get("streams", [])
            video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
            audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
            subtitle_streams = [s for s in streams if s.get("codec_type") == "subtitle"]
            entry["videoCodec"] = video_stream.get("codec_name")
            entry["width"] = video_stream.get("width")
            entry["height"] = video_stream.get("height")
            entry["fps"] = video_stream.get("avg_frame_rate")
            entry["audioCodecs"] = [s.get("codec_name") for s in audio_streams]
            entry["subtitleStreams"] = len(subtitle_streams)
        except Exception as error:
            entry["error"] = shorten(str(error), 200)
            results.append(entry)
            continue

        # 转封装：HLS 切片，测吞吐。
        hls_dir = ensure_dir(perf_dir / "hls" / video.stem)
        for stale in hls_dir.glob("*"):
            stale.unlink()
        code, _, err, elapsed = run([
            str(ffmpeg_bin()), "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(video), "-t", "6", "-c", "copy",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
            "-hls_segment_filename", str(hls_dir / "seg_%03d.ts"),
            str(hls_dir / "index.m3u8")
        ], timeout=300)
        segments = sorted(hls_dir.glob("*.ts"))
        entry["hls"] = {
            "ok": code == 0 and bool(segments),
            "elapsedSeconds": round(elapsed, 3),
            "segments": len(segments),
            "realtimeFactor": round(6 / elapsed, 2) if elapsed > 0 else None,
            "error": None if code == 0 else shorten(err, 200),
        }

        # 重编码：4 秒 H.264 ultrafast。
        transcode_dir = ensure_dir(perf_dir / "transcode" / video.stem)
        for stale in transcode_dir.glob("*"):
            stale.unlink()
        transcode_output = transcode_dir / "out.mp4"
        code, _, err, elapsed = run([
            str(ffmpeg_bin()), "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(video), "-t", "4",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart", str(transcode_output)
        ], timeout=900)
        entry["transcode"] = {
            "ok": code == 0 and transcode_output.exists(),
            "elapsedSeconds": round(elapsed, 3),
            "realtimeFactor": round(4 / elapsed, 2) if elapsed > 0 else None,
            "outputBytes": transcode_output.stat().st_size if transcode_output.exists() else 0,
            "error": None if code == 0 else shorten(err, 200),
        }

        # 拖动：25% / 50% / 75% 各解码一帧。
        seeks = []
        duration = float(entry.get("duration") or 0)
        for ratio in (0.25, 0.5, 0.75):
            if duration <= 0:
                break
            point = max(0.1, duration * ratio)
            code, _, err, elapsed = run([
                str(ffmpeg_bin()), "-hide_banner", "-loglevel", "error",
                "-ss", f"{point:.2f}", "-i", str(video),
                "-frames:v", "1", "-f", "null", "-"
            ], timeout=120)
            seeks.append({"ratio": ratio, "atSeconds": round(point, 2),
                          "ok": code == 0, "elapsedMs": round(elapsed * 1000, 1),
                          "error": None if code == 0 else shorten(err, 160)})
        entry["seek"] = seeks
        results.append(entry)

    avplayer = {}
    if include_avplayer:
        log("- AVPlayer 可播性探测")
        avplayer = avplayer_probe_files([item["path"] for item in results
                                         if not item.get("error")], out)
        for item in results:
            probe = avplayer.get(item["file"])
            if probe:
                item["avplayer"] = {
                    "isPlayable": probe.get("isPlayable"),
                    "itemStatus": probe.get("itemStatus"),
                    "playedSeconds": probe.get("playedSeconds"),
                    "likelyToKeepUp": probe.get("likelyToKeepUp"),
                    "elapsedSeconds": probe.get("elapsedSeconds"),
                    "videoRange": probe.get("videoRange"),
                    "presentationSize": probe.get("presentationSize"),
                    "tracks": [{"type": t.get("type"), "codecs": t.get("codecs"),
                                "decodable": t.get("decodable")}
                               for t in probe.get("tracks", [])],
                }

    report = {"schemaVersion": 1, "generatedAt": now_iso(), "files": results}
    (reports / "video-perf.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    markdown = [
        "# 视频性能基准",
        "",
        f"生成时间：{report['generatedAt']}",
        "",
        "| 文件 | 分辨率 | 视频编码 | 音轨 | 转封装实时倍率 | 重编码实时倍率 | 拖动 p50 | AVPlayer |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | --- |",
    ]
    for item in results:
        if item.get("error"):
            markdown.append(f"| {item['file']} | - | - | - | - | - | - | 失败 |")
            continue
        seek_times = sorted([s["elapsedMs"] for s in item.get("seek", []) if s.get("ok")])
        seek_p50 = seek_times[len(seek_times) // 2] if seek_times else None
        seek_text = "-" if seek_p50 is None else f"{seek_p50:.0f}ms"
        av = item.get("avplayer", {})
        av_text = "-"
        if av:
            av_text = "可播" if av.get("isPlayable") else "不可播"
            if av.get("playedSeconds") is not None:
                av_text += f" / {av['playedSeconds']}s"
        markdown.append(
            f"| {item['file']} | {item.get('width')}x{item.get('height')} | "
            f"{item.get('videoCodec')} | {', '.join(item.get('audioCodecs') or []) or '-'} | "
            f"{item.get('hls', {}).get('realtimeFactor', '-')} | "
            f"{item.get('transcode', {}).get('realtimeFactor', '-')} | "
            f"{seek_text} | {av_text} |")
    markdown += [
        "",
        "> 实时倍率 = 片段秒数 / 实际耗时，> 1.0 表示快于实时。",
        "> 拖动为从 25% / 50% / 75% 位置解码一帧的耗时中位数。",
        "> AVPlayer 结果来自 `Tools/dev/avplayer_probe.swift`，只采集公开 API 的事实。",
        "",
    ]
    (reports / "video-perf.md").write_text("\n".join(markdown), encoding="utf-8")
    log(f"性能报告：{reports / 'video-perf.json'}")
    log(f"可读版本：{reports / 'video-perf.md'}")
    return 0


# ---------------------------------------------------------------------------
# regression 命令
# ---------------------------------------------------------------------------

def cmd_regression(out: Path, with_ui: bool = False) -> int:
    log("回归 1/4：校验测试集")
    code = cmd_validate(out)
    ok = code == 0
    entries = []

    log("回归 2/4：Swift 纯逻辑断言")
    for target in ("LumaCoreChecks", "LumaContentChecks", "LumaDataChecks"):
        code, stdout, stderr, elapsed = run(["swift", "run", target], timeout=1800, cwd=ROOT)
        entries.append({"target": target, "ok": code == 0, "seconds": round(elapsed, 1),
                        "tail": shorten(stderr or stdout, 800)})
        log(f"  {'✓' if code == 0 else '✗'} {target}  {elapsed:.1f}s")
        ok = ok and code == 0

    if with_ui:
        log("回归 3/4：界面截图冒烟")
        code = cmd_screens(out, screens="all", modules=True)
        entries.append({"target": "screens", "ok": code == 0})
        ok = ok and code == 0
    else:
        log("回归 3/4：界面截图（跳过，加 --with-ui 开启）")

    log("回归 4/4：报告")
    report = {"generatedAt": now_iso(), "ok": ok,
              "validation": str(out / "reports/validation.json"), "checks": entries}
    (ensure_dir(out / "reports") / "regression.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    log(f"回归{'通过' if ok else '失败'}：{out / 'reports/regression.json'}")
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Luma 测试集 / 截图 / 性能 / 回归工具")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="产物根目录，默认 ~/Movies/LumaTestKit")
    sub = parser.add_subparsers(dest="command", required=True)

    dataset = sub.add_parser("dataset", help="生成测试集")
    dataset.add_argument("--large", action="store_true", help="额外生成约 300MB 大视频")
    dataset.add_argument("--force", action="store_true", help="覆盖已存在的图片素材")
    dataset.add_argument("--photos", type=int, default=0,
                         help="规模模式：生成 N 张照片（如 5000），按 2010–2026 分年相簿")

    serve = sub.add_parser("serve", help="启动 mock 源服务")
    serve.add_argument("--port", type=int, default=9410)
    serve.add_argument("--host", default="127.0.0.1")

    screens = sub.add_parser("screens", help="采集产品截图")
    screens.add_argument("--screens", default="all", help="页面 id，逗号分隔，或 all")
    screens.add_argument("--build", action="store_true", help="先执行 ./build.sh debug")
    screens.add_argument("--settle", type=float, default=2.5)
    screens.add_argument("--size", default="1440x900")
    screens.add_argument("--no-modules", action="store_true", help="不接入 mock 网盘 / 影院 / 电视")
    screens.add_argument("--port", type=int, default=0)
    screens.add_argument("--app", default=str(APP_BIN),
                         help="指定 Luma 可执行文件（默认仓库内 Luma.app）")
    screens.add_argument("--force", action="store_true",
                         help="跳过「已有 Luma 在运行」检查，用于独立的测试副本")
    screens.add_argument("--keep-library", action="store_true",
                         help="复用上一次的演示库（默认每次重建，避免旧 mock 端口残留）")

    perf = sub.add_parser("perf", help="视频性能基准")
    perf.add_argument("--quick", action="store_true", help="跳过 30MB 以上的样片")
    perf.add_argument("--no-avplayer", action="store_true")

    sub.add_parser("validate", help="校验测试集与 mock 源")

    regression = sub.add_parser("regression", help="校验 + Swift 断言 + 可选界面截图")
    regression.add_argument("--with-ui", action="store_true")

    all_cmd = sub.add_parser("all", help="dataset + validate + screens")
    all_cmd.add_argument("--large", action="store_true")
    all_cmd.add_argument("--build", action="store_true")

    args = parser.parse_args()
    out = Path(args.out).expanduser().resolve()

    if args.command == "dataset":
        cmd_dataset(out, large=args.large, force=args.force, photos=args.photos)
        return 0
    if args.command == "serve":
        return cmd_serve(out / "dataset", args.port, args.host)
    if args.command == "screens":
        return cmd_screens(out, args.screens, build=args.build, settle=args.settle,
                           size=args.size, modules=not args.no_modules, port=args.port,
                           app_bin=Path(args.app), skip_running_check=args.force,
                           fresh=not args.keep_library)
    if args.command == "perf":
        return cmd_perf(out, quick=args.quick, include_avplayer=not args.no_avplayer)
    if args.command == "validate":
        return cmd_validate(out)
    if args.command == "regression":
        return cmd_regression(out, with_ui=args.with_ui)
    if args.command == "all":
        cmd_dataset(out, large=args.large)
        code = cmd_validate(out)
        if code != 0:
            return code
        return cmd_screens(out, screens="all", build=args.build)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
