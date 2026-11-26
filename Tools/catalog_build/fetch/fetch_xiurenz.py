#!/usr/bin/env python3
"""P0 新源：xiurenz.com.cn 微密圈 / 秀人旗下 / 其他机构合集索引。

用法：
    python3 Tools/catalog_build/fetch/fetch_xiurenz.py
    CNY_XZ_MAX_PAGES=3 python3 ...   # 小样验证

输出：Tools/catalog_build/raw/cn_profiles_xiurenz.json

站点是 WordPress，但 REST 被禁用（401）；列表页与 sitemap 仍可公开读取。
每个合集页标题形如「莉莉子Ririko – 秘语空间等写真&视频合集【持续更新中】」，
`–` 前段是真人名，正文首图是封面。这里只做「人物 + 合集计数」，
不把整份合集当成一条作品；精选单套里带 NO. 的才记作品。
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_cn_round10 as base  # noqa: E402

ROOT = base.ROOT
RAW = base.RAW
OUT = os.path.join(RAW, "cn_profiles_xiurenz.json")
HOST = "https://www.xiurenz.com.cn"

CATEGORIES = [
    ("vmhj", "微密圈"),
    ("xrqx", "秀人旗下"),
    ("heji", "合集打包"),
]
# 精选单套 / 其他机构的标题是「机构 NO.xxx 套名」，NO. 后多为套名而不是模特名，
# 解析不出可靠人名，且作品与秀人旗下大量重复，故不纳入本轮。

LINK_RE = re.compile(
    r'<a[^>]+href="(https://www\.xiurenz\.com\.cn/[^"]+)"[^>]*>(.*?)</a>', re.S)
PAGE_LINK_RE = re.compile(r'/page/(\d+)/?')
TITLE_TAG_RE = re.compile(r"<[^>]+>")
COUNT_RE = re.compile(r"(\d{1,4})\s*(?:套|期)")
ALBUM_RE = re.compile(
    r"(?:NO|No|no)\.?\s*(\d{1,5})\s+(.{1,40}?)(?:\s*[\[\(（]|$)")
AGGREGATE = re.compile(r"(全套|合集|合辑|持续更新|资源汇总|汇总|打包|目录|整理)")
# 角色名 / 套名常用词：这些不是模特名。
SET_NAME = re.compile(
    r"(写真书|写真集|DL版|Vol\.|约儿|女仆|护士|制服|泳装|体操服|自拍|绳艺|"
    r"丝袜|内衣|皮衣|度假|夏日|冬日|圣诞|情人节|警察ver|警察|兔女郎)")
CACHE_DIR = os.path.join(RAW, ".xiurenz_pages")


def listing(category, page):
    url = f"{HOST}/{category}/" if page == 1 else f"{HOST}/{category}/page/{page}/"
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, f"{category}_{page:04d}.html")
    if os.path.exists(cache_path):
        return open(cache_path, encoding="utf-8").read()
    text = base.fetch_text(url)
    if text:
        open(cache_path, "w", encoding="utf-8").write(text)
    return text


def collect_links():
    seen = set()
    links = []
    for category, label in CATEGORIES:
        first = listing(category, 1)
        if not first:
            print(f"  {category}: 列表不可达，跳过", flush=True)
            continue
        pages = [int(value) for value in PAGE_LINK_RE.findall(first)] or [1]
        max_page = max(pages)
        limit_pages = int(os.environ.get("CNY_XZ_MAX_PAGES") or 0)
        if limit_pages:
            max_page = min(max_page, limit_pages)
        for page in range(1, max_page + 1):
            text = first if page == 1 else listing(category, page)
            if not text:
                break
            for url, raw_title in LINK_RE.findall(text):
                if url in seen:
                    continue
                title = html.unescape(TITLE_TAG_RE.sub("", raw_title)).strip()
                if not title or len(title) > 120:
                    continue
                # 只收文章页：合集页是「人名 – 套名」，单套页是「[秀人网]日期 NO.xxx 人名」。
                if not re.search(r"(?:\s+[–—\-－]\s+|NO\.?\s*\d{1,5})", title):
                    continue
                seen.add(url)
                links.append({"url": url, "title": title, "category": label})
            if page % 50 == 0:
                print(f"  {category} 第 {page}/{max_page} 页，累计 {len(links)}", flush=True)
            time.sleep(0.12)
    return links


def parse_person(title, category):
    """标题 → (人名, 别名, NO.编号)。

    不同栏目的命名方向不同：
    - 微密圈 / 合集打包：`人名 – 套名`，取 `–` 前段；
    - 秀人旗下：`[Xiuren秀人网] 日期 NO.xxx 人名[规格]`，取 NO. 后段；
    - 精选单套 / 其他机构：`[机构/人名] NO.xxx 套名`，人名在 NO. 前，
      NO. 后多是套名（Jett / 甘雨奶牛），因此只认 NO. 前段，认不出就跳过。
    """
    no = None
    album = ALBUM_RE.search(title)
    if album:
        no = int(album.group(1))
    if category in ("微密圈", "合集打包"):
        head = re.split(r"\s+[–—\-－]\s+", title, maxsplit=1)[0].strip()
        name, aliases = base.clean_name(head)
        if name and not SET_NAME.search(name):
            return name, aliases, no
        return None, [], no
    if category == "秀人旗下":
        if album:
            name, aliases = base.clean_name(album.group(2))
            if name and not SET_NAME.search(name):
                return name, aliases, no
        return None, [], no
    if album:
        head = title[:album.start()]
        bracket = re.match(r"^\s*\[([^\]]{2,30})\]", head)
        candidate = bracket.group(1) if bracket else base.DATE_HEAD.sub("", head).strip()
        name, aliases = base.clean_name(candidate)
        if name and not SET_NAME.search(name):
            return name, aliases, no
        return None, [], no
    head = re.split(r"\s+[–—\-－]\s+", title, maxsplit=1)[0].strip()
    name, aliases = base.clean_name(head)
    if name and not SET_NAME.search(name):
        return name, aliases, no
    return None, [], no


def build():
    print("抓取 xiurenz 分类列表…", flush=True)
    links = collect_links()
    print(f"文章 {len(links)} 条", flush=True)
    people: dict[str, dict] = {}
    first_url: dict[str, str] = {}
    for entry in links:
        name, aliases, no = parse_person(entry["title"], entry["category"])
        if not name:
            continue
        record = people.setdefault(name, {
            "aliases": [], "album_count": 0, "tags": set(),
            "works": [],
        })
        for alias in aliases:
            if alias and alias != name and alias not in record["aliases"]:
                record["aliases"].append(alias)
        record["tags"].add(entry["category"])
        count = COUNT_RE.search(entry["title"])
        if count:
            record["album_count"] = max(record["album_count"], int(count.group(1)))
        # 带 NO. 的是单套作品；合集索引不落 works。
        if no and not AGGREGATE.search(entry["title"]):
            record["works"].append({"no": no, "title": entry["title"][:160], "url": entry["url"]})
        first_url.setdefault(name, entry["url"])
    print(f"人物 {len(people)}，开始取封面…", flush=True)

    table = base.xw.library_names()
    canonical: dict[str, dict] = {}
    for name, record in people.items():
        target_name = base.canonical_name(name, table) or name
        target = canonical.setdefault(target_name, {
            "aliases": [], "album_count": 0, "tags": set(), "works": []})
        if target_name != name:
            target["aliases"].append(name)
        for alias in record["aliases"]:
            if alias != target_name and alias not in target["aliases"]:
                target["aliases"].append(alias)
        target["tags"].update(record["tags"])
        target["album_count"] = max(target["album_count"], record["album_count"])
        target["works"].extend(record["works"])

    # 只给库外/无名册封面的前 500 人取封面，避免 1.8 万篇逐页抓。
    limit = int(os.environ.get("CNY_XZ_COVER_LIMIT") or 500)
    targets = []
    for name in canonical:
        if len(targets) >= limit:
            break
        if name.casefold() in table:
            continue
        url = first_url.get(name)
        if url:
            targets.append((name, url))
    from concurrent.futures import ThreadPoolExecutor

    def grab(item):
        name, url = item
        return name, base.cover_of(base.fetch_text(url))

    with ThreadPoolExecutor(max_workers=8) as pool:
        for index, (name, cover) in enumerate(pool.map(grab, targets), 1):
            canonical[name]["image_url"] = cover
            if index % 200 == 0:
                print(f"  封面 {index}/{len(targets)}", flush=True)

    records = []
    for name, record in canonical.items():
        aliases = [alias for alias in record["aliases"] if alias != name]
        region = base.region_for(name, aliases, "xiurenz")
        works, seen = [], set()
        for work in record["works"]:
            if work["url"] in seen:
                continue
            seen.add(work["url"])
            works.append(work)
        album_count = max(record["album_count"], len(works))
        records.append({
            "name": name,
            "aliases": aliases,
            "region": region,
            "image_url": record.get("image_url"),
            "tags": sorted(record["tags"]),
            "summary": "微密圈 / 写真合集网红。" if album_count else None,
            "album_count": album_count or None,
            "source": "xiurenz",
            "source_url": first_url.get(name, ""),
            "works": works[:400],
        })
    records.sort(key=lambda row: -(row.get("album_count") or 0))
    tmp = OUT + ".tmp"
    json.dump(records, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)
    print(f"完成：{len(records)} 人（有封面 {sum(1 for r in records if r.get('image_url'))}）→ {OUT}")


if __name__ == "__main__":
    build()
