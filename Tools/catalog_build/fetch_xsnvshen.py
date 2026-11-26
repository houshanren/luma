#!/usr/bin/env python3
"""第六轮：秀色女神（xsnvshen.com）全量人物档案。

用法：python3 Tools/catalog_build/fetch_xsnvshen.py
输出：Tools/catalog_build/raw/cn_profiles_xsnvshen.json

站点结构：
- 列表页 https://www.xsnvshen.com/girl?p=N （共约 1.1 万位，每页 25 位）
- 资料页 https://www.xsnvshen.com/girl/{id}
  <li><span class='bas-title'>生日</span><span class='bas-cont'>1996-08-22</span></li>
  字段：名字/中文名/英文名/别名/生日/星座/属相/血型/身高/体重/三围/出生/职业/兴趣/收录图集
  另有简介、社交账号（微博等）、图集列表（作品）。

公开资料整合站，只取文字档案与作品目录，不下载图片。
"""

from __future__ import annotations

import html
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "cn_profiles_xsnvshen.json")
BASE = "https://www.xsnvshen.com"
PROXIES = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"),
    "Accept-Language": "zh-CN,zh;q=0.9",
})

FIELD_RE = re.compile(
    r"<li><span\s+class=['\"]bas-title['\"]>([^<]+)</span>"
    r"<span\s+class=['\"]bas-cont['\"]>([^<]*)</span></li>")
INTRO_RE = re.compile(r"star2-intro-bd[^>]*>\s*<p>(.*?)</p>", re.S)
ALBUM_RE = re.compile(r'<a\s+href="/album/(\d+)"\s+title="([^"]+)"')
BWH_RE = re.compile(r"B\s*(\d{2,3})\s*W\s*(\d{2,3})\s*H\s*(\d{2,3})", re.I)
DATE_RE = re.compile(r"((?:19|20)\d{2})[-年./](\d{1,2})[-月./](\d{1,2})")

REGION_MAP = (
    ("韩国", "korea"), ("朝鲜", "korea"),
    ("日本", "japan"),
    ("中国台湾", "taiwan"), ("台湾", "taiwan"),
    ("中国香港", "hongkong"), ("香港", "hongkong"),
    ("中国澳门", "macau"), ("澳门", "macau"),
    ("中国", "china"),
)


def session_with_proxy():
    try:
        probe = SESSION.get(BASE + "/girl", proxies=PROXIES, timeout=10)
        if probe.status_code == 200:
            SESSION.proxies.update(PROXIES)
            return "proxy7890"
    except requests.RequestException:
        pass
    return "direct"


def fetch(url, tries=4):
    for attempt in range(tries):
        try:
            r = SESSION.get(url, timeout=25)
            if r.status_code == 200:
                return r.text
            if r.status_code == 404:
                return None
            time.sleep(2 * (attempt + 1))
        except requests.RequestException:
            time.sleep(2 * (attempt + 1))
    return None


def girl_ids():
    """列表页翻页，收集全部女神 id。"""
    first = fetch(BASE + "/girl?p=1")
    if not first:
        raise SystemExit("列表页抓取失败")
    total = 0
    m = re.search(r"共\s*(\d+)\s*位", re.sub(r"<[^>]+>", "", first))
    if m:
        total = int(m.group(1))
    ids: list[str] = []
    seen = set()
    page = 1
    per_page = 25
    pages = (total // per_page) + 2 if total else 500
    while page <= pages:
        text = first if page == 1 else fetch(f"{BASE}/girl?p={page}")
        if not text:
            break
        found = re.findall(r'href="(/girl/(\d+))"', text)
        new = 0
        for _href, gid in found:
            if gid not in seen:
                seen.add(gid)
                ids.append(gid)
                new += 1
        if page % 40 == 0:
            print(f"  列表第 {page} 页，累计 {len(ids)} 个 id", flush=True)
        if new == 0 and page > 1:
            # 两页都没有新增（列表尾部循环），停止
            break
        if total and len(seen) >= total and page > 1 and new == 0:
            break
        page += 1
        time.sleep(0.25)
    print(f"列表完成：共 {len(ids)} 个女神 id（站点公布 {total} 位）", flush=True)
    return ids


def region_of(place):
    if not place:
        return None
    for prefix, region in REGION_MAP:
        if place.startswith(prefix):
            return region
    if re.search(r"[ぁ-んァ-ヶ]", place):
        return "japan"
    if re.search(r"[\uac00-\ud7af]", place):
        return "korea"
    return "china"


def birthplace_of(place):
    if not place:
        return None
    text = place.strip()
    for prefix in ("中国台湾", "中国香港", "中国澳门", "中国"):
        if text.startswith(prefix):
            rest = text[len(prefix):].strip()
            if prefix in ("中国台湾", "中国香港", "中国澳门"):
                return (prefix[2:] + " " + rest).strip() if rest else prefix[2:]
            return rest or None
    return text or None


def parse_girl(gid, text):
    fields = {}
    for key, value in FIELD_RE.findall(text or ""):
        fields[key.strip()] = html.unescape(value).strip()

    name = fields.get("名字") or ""
    if not name or len(name) > 40:
        return None
    aliases = []
    for key in ("中文名", "英文名", "别名"):
        value = fields.get(key)
        if value and value != name and len(value) <= 40:
            aliases.append(value)

    birth_date = None
    m = DATE_RE.search(fields.get("生日") or "")
    if m:
        y, mo, d = (int(x) for x in m.groups())
        if 1940 <= y <= 2012 and 1 <= mo <= 12 and 1 <= d <= 31:
            birth_date = f"{y:04d}-{mo:02d}-{d:02d}"

    height = weight = None
    m = re.search(r"(\d{2,3})", fields.get("身高") or "")
    if m and 140 <= int(m.group(1)) <= 195:
        height = int(m.group(1))
    m = re.search(r"(\d{2,3})", fields.get("体重") or "")
    if m and 35 <= int(m.group(1)) <= 90:
        weight = int(m.group(1))

    bust = waist = hips = None
    m = BWH_RE.search(fields.get("三围") or "")
    if m:
        b, w, h = (int(x) for x in m.groups())
        if all(40 <= v <= 150 for v in (b, w, h)) and b > w:
            bust, waist, hips = b, w, h

    place = fields.get("出生") or ""
    summary = None
    m = INTRO_RE.search(text or "")
    if m:
        summary = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html.unescape(m.group(1)))).strip()
        summary = summary[:300] or None

    socials = {}
    for platform, pattern in (
        ("weibo", r"weibo\.com/(?:u/)?([A-Za-z0-9_\-]{4,40})"),
        ("bilibili", r"bilibili\.com/(\d{4,12})"),
        ("twitter", r"(?:twitter|x)\.com/([A-Za-z0-9_]{2,30})"),
        ("instagram", r"instagram\.com/([A-Za-z0-9_.]{2,30})"),
    ):
        m = re.search(pattern, text or "")
        if m and m.group(1).lower() not in {"share", "login", "home", "u"}:
            socials[platform] = {"handle": m.group(1), "url": m.group(0)}

    works = []
    seen_album = set()
    for aid, title in ALBUM_RE.findall(text or ""):
        if aid in seen_album:
            continue
        seen_album.add(aid)
        title = html.unescape(title).strip()
        if not title or len(title) > 120:
            continue
        works.append({"no": int(aid), "title": title,
                      "url": f"{BASE}/album/{aid}"})

    tags = []
    for job in re.split(r"[、,，/]", fields.get("职业") or ""):
        job = job.strip()
        if job in ("模特", "平面模特", "Coser", "网红", "主播", "演员") and job not in tags:
            tags.append("Coser" if job == "Coser" else job)
    if "cos" in (text or "").lower() and "Coser" not in tags:
        tags.append("Coser")

    record = {
        "name": name,
        "aliases": aliases,
        "region": region_of(place),
        "birth_date": birth_date,
        "height": height,
        "weight": weight,
        "bust": bust,
        "waist": waist,
        "hips": hips,
        "birthplace": birthplace_of(place),
        "blood_type": (fields.get("血型") or None),
        "hobby": fields.get("兴趣") or None,
        "constellation": fields.get("星座") or None,
        "tags": tags,
        "summary": summary,
        "socials": socials,
        "image_url": f"https://img.xsnvshen.com/album/{gid}/{gid}.jpg",
        "album_count": len(works),
        "source": "xsnvshen",
        "source_url": f"{BASE}/girl/{gid}",
        "works": works[:120],
    }
    return record if any(record.get(f) for f in
                         ("birth_date", "height", "bust", "birthplace", "summary",
                          "image_url", "aliases")) else None


def load_done():
    if os.path.exists(OUT):
        try:
            data = json.load(open(OUT, encoding="utf-8"))
            return {row["source_url"].rsplit("/", 1)[-1]: row for row in data}, data
        except (ValueError, KeyError):
            pass
    return {}, []


def save(records):
    tmp = OUT + ".tmp"
    json.dump(records, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)


def main():
    os.makedirs(RAW, exist_ok=True)
    mode = session_with_proxy()
    print(f"网络通道：{mode}", flush=True)
    done, records = load_done()
    print(f"已有 {len(done)} 条，断点续抓", flush=True)

    ids = girl_ids()
    pending = [gid for gid in ids if gid not in done]
    print(f"待抓 {len(pending)} 个资料页", flush=True)

    lock_counts = {"done": 0}

    def work(gid):
        text = fetch(f"{BASE}/girl/{gid}")
        if text is None:
            return None
        return parse_girl(gid, text)

    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {pool.submit(work, gid): gid for gid in pending}
        for future in as_completed(futures):
            gid = futures[future]
            try:
                record = future.result()
            except Exception:
                record = None
            if record:
                records.append(record)
                done[gid] = record
            lock_counts["done"] += 1
            if lock_counts["done"] % 200 == 0:
                print(f"  进度 {lock_counts['done']}/{len(pending)}，有效 {len(records)} 条",
                      flush=True)
                save(records)
        save(records)

    save(records)
    stats = {
        "总数": len(records),
        "生日": sum(1 for r in records if r.get("birth_date")),
        "身高": sum(1 for r in records if r.get("height")),
        "三围": sum(1 for r in records if r.get("bust")),
        "出身地": sum(1 for r in records if r.get("birthplace")),
        "微博": sum(1 for r in records if r.get("socials", {}).get("weibo")),
    }
    print(f"完成：{stats} → {OUT}")


if __name__ == "__main__":
    main()
