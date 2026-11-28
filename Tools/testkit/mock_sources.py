#!/usr/bin/env python3
"""拾光 Luma 测试集 · 本地 mock 源服务。

一个进程同时提供四类测试源，全部指向本地测试集，不访问外网：

1. `/webdav/...`  —— WebDAV：PROPFIND（Depth 0/1）+ GET/HEAD + Range，
   对应「网络存储」模块的目录树、缩略图、视频拖动。
2. `/cms/api.php/provide/vod/` —— 苹果CMS V10 JSON 接口，
   对应「网络影院」的列表 / 分类 / 搜索 / 详情 / 分集播放。
3. `/hls/...` —— 本地 HLS 切片，对应影院 / 网络影院 / 电视直播播放。
4. `/epg.xml` 与 `/playlist.m3u` —— XMLTV 节目单与多线路 M3U，
   对应「网络电视」的频道墙、节目单、回看与选线。
5. `/`、`/file/...`、`/tags/...` —— 图集站 HTML（Tuzac 页面结构），
   对应「网络资源」的源导入、频道列表、图集详情与标签墙。

用法：
    python3 Tools/testkit/mock_sources.py --dataset ~/Movies/LumaTestKit/dataset
    python3 Tools/testkit/mock_sources.py --dataset ... --port 9410 --host 127.0.0.1

启动后会在 stdout 打印：
    LUMA_TESTKIT_SERVER=http://127.0.0.1:9410
同时把运行时的 M3U 写到 `<dataset>/live/playlist.runtime.m3u`。
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import mimetypes
import os
import posixpath
import re
import socketserver
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]

# 网络影院条目：标题、类型、年份、备注、分集数。
CATALOG_ITEMS = [
    {"id": 101, "title": "春日序曲", "type": 1, "year": "2025", "remarks": "HD 中字", "episodes": 1},
    {"id": 102, "title": "海边来信", "type": 1, "year": "2024", "remarks": "HD 中字", "episodes": 1},
    {"id": 103, "title": "城市漫游", "type": 1, "year": "2026", "remarks": "抢先版", "episodes": 1},
    {"id": 104, "title": "夜色将明", "type": 1, "year": "2023", "remarks": "蓝光", "episodes": 1},
    {"id": 105, "title": "山与海", "type": 1, "year": "2025", "remarks": "HD", "episodes": 1},
    {"id": 106, "title": "雾中灯塔", "type": 1, "year": "2024", "remarks": "HD 中字", "episodes": 1},
    {"id": 201, "title": "拾光公寓", "type": 2, "year": "2026", "remarks": "更新至 06 集", "episodes": 6},
    {"id": 202, "title": "缓慢的夏天", "type": 2, "year": "2025", "remarks": "全 4 集", "episodes": 4},
    {"id": 203, "title": "星图计划", "type": 2, "year": "2026", "remarks": "更新至 08 集", "episodes": 8},
    {"id": 301, "title": "云端物语", "type": 3, "year": "2026", "remarks": "更新中", "episodes": 5},
    {"id": 302, "title": "小镇日常", "type": 3, "year": "2024", "remarks": "全 12 话", "episodes": 12},
    {"id": 401, "title": "拾光放映室", "type": 4, "year": "2026", "remarks": "第 3 期", "episodes": 3},
]

# 网络资源（图集站）：按 Tuzac 的页面结构组织，供「网络资源」模块做列表与详情测试。
GALLERY_SETS = [
    {"slug": "seaside-morning", "title": "海边清晨", "count": 12},
    {"slug": "mountain-hike", "title": "山间徒步", "count": 9},
    {"slug": "city-night", "title": "城市夜色", "count": 15},
    {"slug": "summer-street", "title": "夏日街头", "count": 8},
    {"slug": "old-town", "title": "老城巷口", "count": 11},
    {"slug": "after-rain", "title": "雨后玻璃", "count": 7},
    {"slug": "tide-lighthouse", "title": "潮汐与灯塔", "count": 13},
    {"slug": "winter-station", "title": "冬日车站", "count": 10},
    {"slug": "desert-road", "title": "沙漠公路", "count": 6},
    {"slug": "lakeside-dusk", "title": "湖畔黄昏", "count": 14},
    {"slug": "roof-garden", "title": "屋顶花园", "count": 9},
    {"slug": "night-market", "title": "夜市灯火", "count": 16},
]

CATEGORY_ROWS = [
    {"type_id": 1, "type_pid": 0, "type_name": "电影"},
    {"type_id": 2, "type_pid": 0, "type_name": "电视剧"},
    {"type_id": 3, "type_pid": 0, "type_name": "动漫"},
    {"type_id": 4, "type_pid": 0, "type_name": "综艺"},
    {"type_id": 6, "type_pid": 1, "type_name": "动作片"},
    {"type_id": 7, "type_pid": 1, "type_name": "剧情片"},
    {"type_id": 13, "type_pid": 2, "type_name": "国产剧"},
    {"type_id": 14, "type_pid": 2, "type_name": "欧美剧"},
]

TV_CHANNELS = [
    {"id": "cctv1", "name": "CCTV-1 综合", "group": "央视", "city": "北京", "logo": "cctv1"},
    {"id": "cctv2", "name": "CCTV-2 财经", "group": "央视", "city": "北京", "logo": "cctv2"},
    {"id": "cctv6", "name": "CCTV-6 电影", "group": "央视", "city": "北京", "logo": "cctv6"},
    {"id": "sat1", "name": "东方卫视", "group": "卫视", "city": "上海", "logo": "sat1"},
    {"id": "sat2", "name": "湖南卫视", "group": "卫视", "city": "湖南", "logo": "sat2"},
    {"id": "local1", "name": "杭州综合", "group": "地方", "city": "浙江", "logo": "local1"},
    {"id": "local2", "name": "深圳都市", "group": "地方", "city": "广东", "logo": "local2"},
    {"id": "test1", "name": "Luma 测试频道", "group": "测试", "city": "北京", "logo": "test1"},
]

PROGRAM_TITLES = [
    "新闻联播", "朝闻天下", "纪录片：山海之间", "动画剧场", "电视剧：拾光公寓",
    "电影：春日序曲", "综艺：拾光放映室", "晚间新闻", "音乐现场", "体育快讯"
]


class State:
    dataset: Path
    host: str
    port: int

    @property
    def base(self) -> str:
        return f"http://{self.host}:{self.port}"


STATE = State()


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def safe_join(root: Path, relative: str) -> Path | None:
    relative = urllib.parse.unquote(relative).lstrip("/")
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        return None
    return candidate


def http_date(timestamp: float) -> str:
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")


def content_type(path: Path) -> str:
    if path.suffix.lower() == ".m3u8":
        return "application/vnd.apple.mpegurl"
    if path.suffix.lower() == ".ts":
        return "video/mp2t"
    guessed, _ = mimetypes.guess_type(str(path))
    return guessed or "application/octet-stream"


def xml_escape(value: str) -> str:
    return escape(value)


def poster_path(item_id: int) -> str:
    return f"/posters/poster_{item_id:03d}.jpg"


# ---------------------------------------------------------------------------
# 网络资源图集站（Tuzac 页面结构）
# ---------------------------------------------------------------------------

# 海报循环使用测试集里的 2:3 竖图，刚好是图集卡片需要的比例。
GALLERY_POSTER_IDS = [101, 102, 103, 104, 105, 201, 202, 203, 301, 302, 401, 106]


def gallery_cover_url(index: int) -> str:
    poster = GALLERY_POSTER_IDS[index % len(GALLERY_POSTER_IDS)]
    return STATE.base + poster_path(poster)


def gallery_home_html() -> str:
    cards = []
    for index, item in enumerate(GALLERY_SETS):
        cover = gallery_cover_url(index)
        cards.append(
            f'<a class="file-card" href="/file/{item["slug"]}">'
            f'<img data-src="{cover}" alt="{item["title"]}" loading="lazy">'
            f'<h3>{item["title"]}</h3><span>{item["count"]}P</span></a>'
        )
    return (
        "<!doctype html><html><head><meta charset=\"utf-8\">"
        "<meta property=\"og:title\" content=\"拾光测试图集\">"
        f"<title>拾光测试图集</title></head><body>"
        f"<h1>拾光测试图集</h1><div class=\"files\">{''.join(cards)}</div>"
        "</body></html>"
    )


def gallery_detail_html(slug: str) -> str:
    item = next((entry for entry in GALLERY_SETS if entry["slug"] == slug), None)
    if item is None:
        return ""
    total = item["count"]
    images = []
    for number in range(1, total + 1):
        poster = GALLERY_POSTER_IDS[(number - 1) % len(GALLERY_POSTER_IDS)]
        # 详情页只认 tuzac.com 的大图；把标记放在查询串里，图片实际仍由本地服务提供。
        images.append(
            f'<img data-photo-num="{number}" '
            f'src="{STATE.base}{poster_path(poster)}?from=tuzac.com" alt="{item["title"]} 第 {number} 张">'
        )
    return (
        "<!doctype html><html><head><meta charset=\"utf-8\">"
        f"<title>{item['title']} ({total}P)</title></head><body>"
        f"<h1>{item['title']} ({total}P)</h1>"
        f"<div class=\"file-body\">{''.join(images)}</div>"
        f"<div class=\"file-tags\">"
        f'<a class="tag" href="/tags/旅行">旅行</a>'
        f'<a class="tag" href="/tags/拾光">拾光</a></div>'
        "</body></html>"
    )


def gallery_tags_html() -> str:
    rows = [
        f'<article class="tag-name"><a href="/tags/{name}">{name} ({12 + index})</a></article>'
        for index, name in enumerate(["旅行", "海边", "城市", "山野", "夜色", "拾光"])
    ]
    return ("<!doctype html><html><head><meta charset=\"utf-8\">"
            f"<title>全部标签</title></head><body>{''.join(rows)}</body></html>")


def catalog_item_payload(item: dict) -> dict:
    type_name = next((row["type_name"] for row in CATEGORY_ROWS if row["type_id"] == item["type"]), "影视")
    episodes = []
    for index in range(1, item["episodes"] + 1):
        channel = f"channel{(item['id'] + index) % 4 + 1}"
        episodes.append(f"第{index}集${STATE.base}/hls/{channel}/index.m3u8")
        episodes.append(f"线路2-第{index}集${STATE.base}/hls/channel{(index % 4) + 1}/index.m3u8")
    # MacCMS：`#` 分隔集，`$$$` 分隔线路；优先选择 m3u8 数量最多的线路。
    line_main = "#".join(episodes[0::2])
    line_backup = "#".join(episodes[1::2])
    return {
        "vod_id": item["id"],
        "vod_name": item["title"],
        "vod_pic": STATE.base + poster_path(item["id"]),
        "vod_remarks": item["remarks"],
        "type_id": item["type"],
        "type_name": type_name,
        "vod_year": item["year"],
        "vod_area": "中国大陆",
        "vod_lang": "国语",
        "vod_director": "拾光测试组",
        "vod_actor": "林一, 周野, 陈夏",
        "vod_content": f"《{item['title']}》是拾光测试集里的示例条目，用于验证网络影院的列表、详情、分集与播放链路。",
        "vod_play_from": "luma$$$backup",
        "vod_play_url": line_main + "$$$" + line_backup,
    }


# ---------------------------------------------------------------------------
# 请求处理
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "LumaTestKit/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: N802 - BaseHTTPRequestHandler 约定
        if os.environ.get("LUMA_TESTKIT_VERBOSE") == "1":
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- 通用 ---------------------------------------------------------------

    def _send(self, status: int, body: bytes = b"", content_type_value: str = "text/plain; charset=utf-8",
              extra_headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type_value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("DAV", "1, 2")
        self.send_header("Allow", "OPTIONS, GET, HEAD, PROPFIND")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _file(self, path: Path, head_only: bool = False) -> None:
        try:
            size = path.stat().st_size
            etag = f'"{int(path.stat().st_mtime)}-{size}"'
            range_header = self.headers.get("Range")
            start, end = 0, size - 1
            status = 200
            if range_header:
                match = re.match(r"bytes=(\d*)-(\d*)", range_header.strip())
                if match:
                    if match.group(1):
                        start = int(match.group(1))
                    if match.group(2):
                        end = min(int(match.group(2)), size - 1)
                    if start > end or start >= size:
                        self._send(416, b"", "text/plain", {"Content-Range": f"bytes */{size}"})
                        return
                    status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", content_type(path))
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", etag)
            self.send_header("Last-Modified", http_date(path.stat().st_mtime))
            self.send_header("Access-Control-Allow-Origin", "*")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if self.command == "HEAD":
                return
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    # -- 路由 ---------------------------------------------------------------

    def do_OPTIONS(self):  # noqa: N802
        self._send(200, b"", "text/plain")

    def do_HEAD(self):  # noqa: N802
        self.do_GET(head_only=True)

    def do_GET(self, head_only: bool = False):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/health":
            self._json({
                "ok": True,
                "base": STATE.base,
                "dataset": str(STATE.dataset),
                "catalogItems": len(CATALOG_ITEMS),
                "gallerySets": len(GALLERY_SETS),
                "tvChannels": len(TV_CHANNELS),
            })
            return
        # 网络资源图集站：根地址即站点首页，导入探针会直接请求 `/`。
        if path in ("/", "/newest", "/featured") or re.fullmatch(r"/(newest|featured)/\d+", path):
            self._send(200, gallery_home_html().encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/all-tags" or re.fullmatch(r"/all-tags/\d+", path):
            self._send(200, gallery_tags_html().encode("utf-8"), "text/html; charset=utf-8")
            return
        if path.startswith("/tags/"):
            self._send(200, gallery_home_html().encode("utf-8"), "text/html; charset=utf-8")
            return
        match = re.fullmatch(r"/file/([^/]+)/?", path)
        if match:
            body = gallery_detail_html(match.group(1))
            if body:
                self._send(200, body.encode("utf-8"), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found")
            return
        if path.startswith("/webdav"):
            relative = path[len("/webdav"):]
            target = safe_join(STATE.dataset / "cloud", relative)
            if target is None:
                self._send(403)
                return
            if target.is_dir():
                # 简单目录：给浏览器 / curl 一个可读页面；WebDAV 客户端走 PROPFIND。
                body = "<html><body><pre>" + "\n".join(
                    sorted(p.name + ("/" if p.is_dir() else "") for p in target.iterdir())
                ) + "</pre></body></html>"
                self._send(200, body.encode("utf-8"), "text/html; charset=utf-8")
                return
            if target.is_file():
                self._file(target, head_only=head_only)
                return
            self._send(404)
            return
        if path == "/cms/api.php/provide/vod/" or path == "/cms/api.php/provide/vod":
            self._catalog(parsed)
            return
        if path == "/epg.xml":
            self._send(200, build_epg().encode("utf-8"), "application/xml; charset=utf-8")
            return
        if path == "/playlist.m3u":
            self._send(200, build_m3u().encode("utf-8"), "application/vnd.apple.mpegurl")
            return
        for prefix, root in (
            ("/posters", STATE.dataset / "catalog" / "posters"),
            ("/fanart", STATE.dataset / "catalog" / "fanart"),
            ("/hls", STATE.dataset / "live" / "hls"),
            ("/logos", STATE.dataset / "live" / "logos"),
            ("/cinema", STATE.dataset / "cinema"),
        ):
            if path.startswith(prefix):
                target = safe_join(root, path[len(prefix):])
                if target and target.is_file():
                    self._file(target, head_only=head_only)
                    return
        self._send(404, b"not found")

    def do_PROPFIND(self):  # noqa: N802
        # PROPFIND 带 XML 请求体；不读会把残留字节留在 keep-alive 连接里。
        length = int(self.headers.get("Content-Length") or 0)
        if length > 0:
            self.rfile.read(length)
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.startswith("/webdav"):
            self._send(404)
            return
        relative = parsed.path[len("/webdav"):]
        root = STATE.dataset / "cloud"
        target = safe_join(root, relative)
        if target is None or not target.exists():
            self._send(404)
            return
        depth = (self.headers.get("Depth") or "0").strip()
        include_self = True
        entries: list[Path] = [target]
        if depth != "0" and target.is_dir():
            entries += sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        payload = self._multistatus(entries, root, include_self=include_self)
        self._send(207, payload.encode("utf-8"), "application/xml; charset=utf-8")

    def _multistatus(self, entries: list[Path], root: Path, include_self: bool) -> str:
        lines = ['<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">']
        for index, entry in enumerate(entries):
            if index == 0 and not include_self:
                continue
            try:
                relative = entry.relative_to(root).as_posix()
            except ValueError:
                relative = entry.name
            if entry == root:
                href = "/webdav/"
            else:
                href = "/webdav/" + urllib.parse.quote(relative)
                if entry.is_dir() and not href.endswith("/"):
                    href += "/"
            stat = entry.stat()
            resource_type = "<D:collection/>" if entry.is_dir() else ""
            length = "" if entry.is_dir() else f"<D:getcontentlength>{stat.st_size}</D:getcontentlength>"
            modified = http_date(stat.st_mtime)
            item_type = "httpd/unix-directory" if entry.is_dir() else content_type(entry)
            lines += [
                "  <D:response>",
                f"    <D:href>{xml_escape(href)}</D:href>",
                "    <D:propstat>",
                "      <D:prop>",
                f"        <D:displayname>{xml_escape(entry.name)}</D:displayname>",
                f"        <D:getlastmodified>{modified}</D:getlastmodified>",
                f"        <D:getcontenttype>{item_type}</D:getcontenttype>",
                f"        {length}",
                f"        <D:resourcetype>{resource_type}</D:resourcetype>",
                "      </D:prop>",
                "      <D:status>HTTP/1.1 200 OK</D:status>",
                "    </D:propstat>",
                "  </D:response>",
            ]
        lines.append("</D:multistatus>")
        return "\n".join(lines)

    def _catalog(self, parsed) -> None:
        query = urllib.parse.parse_qs(parsed.query)
        action = (query.get("ac") or ["list"])[0]
        page = int((query.get("pg") or ["1"])[0] or 1)
        payloads = [catalog_item_payload(item) for item in CATALOG_ITEMS]
        if action == "list":
            # 导入探针：一次拿到分类与一页列表。
            self._json({
                "code": 1,
                "msg": "ok",
                "page": 1,
                "pagecount": 1,
                "limit": 20,
                "total": len(payloads),
                "class": CATEGORY_ROWS,
                "list": payloads[:20],
            })
            return
        ids = (query.get("ids") or [""])[0]
        category = (query.get("t") or [""])[0]
        keyword = (query.get("wd") or [""])[0].strip()
        selected = payloads
        if ids:
            wanted = {value.strip() for value in ids.split(",") if value.strip()}
            selected = [item for item in selected if str(item["vod_id"]) in wanted]
        if category:
            selected = [item for item in selected if str(item["type_id"]) == category]
        if keyword:
            selected = [item for item in selected if keyword.lower() in item["vod_name"].lower()]
        self._json({
            "code": 1,
            "msg": "ok",
            "page": page,
            "pagecount": 1,
            "limit": 20,
            "total": len(selected),
            "list": selected,
        })


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------------------
# 节目单 / M3U
# ---------------------------------------------------------------------------

def build_epg() -> str:
    now = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).replace(minute=0, second=0, microsecond=0)
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<tv generator-info-name="Luma TestKit">']
    for channel in TV_CHANNELS:
        lines.append(f'  <channel id="{channel["id"]}">')
        lines.append(f'    <display-name>{xml_escape(channel["name"])}</display-name>')
        lines.append(f'    <icon src="{STATE.base}/logos/{channel["logo"]}.png"/>')
        lines.append("  </channel>")
    for day_offset in range(-3, 4):
        day_start = now + dt.timedelta(days=day_offset)
        for slot in range(12):
            start = day_start + dt.timedelta(hours=slot * 2)
            stop = start + dt.timedelta(hours=2)
            for index, channel in enumerate(TV_CHANNELS):
                title = PROGRAM_TITLES[(slot + index) % len(PROGRAM_TITLES)]
                description = f"{channel['name']} · {title} · 测试节目单"
                lines.append(
                    f'  <programme start="{start.strftime("%Y%m%d%H%M%S")} +0800" '
                    f'stop="{stop.strftime("%Y%m%d%H%M%S")} +0800" channel="{channel["id"]}">'
                )
                lines.append(f'    <title lang="zh">{xml_escape(title)}</title>')
                lines.append(f'    <desc lang="zh">{xml_escape(description)}</desc>')
                lines.append("  </programme>")
    lines.append("</tv>")
    return "\n".join(lines)


def build_m3u() -> str:
    lines = [f'#EXTM3U x-tvg-url="{STATE.base}/epg.xml"']
    for index, channel in enumerate(TV_CHANNELS):
        channel_url = f'{STATE.base}/hls/channel{index % 4 + 1}/index.m3u8'
        catchup = ""
        if channel["id"] == "test1":
            catchup = (f' catchup="append" '
                       f'catchup-source="{STATE.base}/hls/channel1/index.m3u8?start=${{start}}&end=${{end}}"')
        lines.append(
            f'#EXTINF:-1 tvg-id="{channel["id"]}" tvg-name="{channel["name"]}" '
            f'tvg-logo="{STATE.base}/logos/{channel["logo"]}.png" '
            f'group-title="{channel["group"]}"{catchup},{channel["name"]}'
        )
        lines.append(f'#EXTGRP:{channel["group"]}')
        lines.append(f'#EXTVLCOPT:http-referrer={STATE.base}/')
        lines.append(channel_url)
        # 同一频道给 3 条线路，验证跨源聚合与备用线路。
        if channel["id"] in ("cctv1", "test1"):
            for offset in (1, 2):
                lines.append(
                    f'#EXTINF:-1 tvg-id="{channel["id"]}" tvg-name="{channel["name"]}" '
                    f'tvg-logo="{STATE.base}/logos/{channel["logo"]}.png" '
                    f'group-title="{channel["group"]}",{channel["name"]} · 线路 {offset + 1}'
                )
                lines.append(f'#EXTVLCOPT:http-referrer={STATE.base}/')
                lines.append(f'{STATE.base}/hls/channel{(index + offset) % 4 + 1}/index.m3u8')
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Luma 测试集 mock 源服务")
    parser.add_argument("--dataset", default=str(Path.home() / "Movies/LumaTestKit/dataset"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9410)
    parser.add_argument("--write-runtime", action="store_true",
                        help="把 M3U 写到 dataset/live/playlist.runtime.m3u 后退出")
    args = parser.parse_args()

    STATE.dataset = Path(args.dataset).expanduser().resolve()
    STATE.host = args.host
    STATE.port = args.port
    if not STATE.dataset.exists():
        raise SystemExit(f"测试集不存在：{STATE.dataset}，先运行 python3 Tools/testkit/testkit.py dataset")

    if args.write_runtime:
        live = STATE.dataset / "live"
        live.mkdir(parents=True, exist_ok=True)
        (live / "playlist.runtime.m3u").write_text(build_m3u(), encoding="utf-8")
        (live / "epg.runtime.xml").write_text(build_epg(), encoding="utf-8")
        print(f"已写入 {live / 'playlist.runtime.m3u'}")
        return

    server = Server((args.host, args.port), Handler)
    base = STATE.base
    print(f"LUMA_TESTKIT_SERVER={base}", flush=True)
    print(f"WebDAV:   {base}/webdav/", flush=True)
    print(f"苹果CMS:  {base}/cms/api.php/provide/vod/", flush=True)
    print(f"EPG:      {base}/epg.xml", flush=True)
    print(f"M3U:      {base}/playlist.m3u", flush=True)
    live = STATE.dataset / "live"
    live.mkdir(parents=True, exist_ok=True)
    (live / "playlist.runtime.m3u").write_text(build_m3u(), encoding="utf-8")
    (live / "epg.runtime.xml").write_text(build_epg(), encoding="utf-8")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
