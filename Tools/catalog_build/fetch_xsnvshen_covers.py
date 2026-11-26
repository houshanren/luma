#!/usr/bin/env python3
"""修正 cn_profiles_xsnvshen.json 的 image_url。

背景（2026-11-25）：fetch_xsnvshen.py 抓资料页时猜的头像 URL
`https://img.xsnvshen.com/album/{gid}/{gid}.jpg` 实际是 403（防盗链）。
真实封面在列表页卡片：`//img.xsnvshen.com/thumb_205x308/album/{aid}/{aid}.jpg`，
其中封面 album id 不一定等于 girl id，必须翻列表页解析。

本脚本翻全部列表页（约 470 页），建立 gid → 封面 URL 映射，
把 JSON 里每个 source_url=/girl/{gid} 记录的 image_url 换成真实封面。
失败的（404/未出现在列表页）置 None（保留原值会拖累头像批量下载）。

用法：python3 Tools/catalog_build/fetch_xsnvshen_covers.py
"""

from __future__ import annotations

import json
import os
import re
import time

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
TARGET = os.path.join(RAW, "cn_profiles_xsnvshen.json")
BASE = "https://www.xsnvshen.com"
PROXIES = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"),
    "Accept-Language": "zh-CN,zh;q=0.9",
})

CARD_RE = re.compile(
    r'<a\s+href="/girl/(\d+)"[^>]*>\s*'
    r'<img[^>]+src="(//img\.xsnvshen\.com/thumb_205x308/album/(\d+)/\3\.jpg)"')

OUT = os.path.join(RAW, "xsnvshen_covers.json")


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


def main():
    try:
        probe = SESSION.get(BASE + "/girl", proxies=PROXIES, timeout=10)
        if probe.status_code == 200:
            SESSION.proxies.update(PROXIES)
    except requests.RequestException:
        pass

    covers: dict[str, str] = {}
    if os.path.exists(OUT):
        covers = json.load(open(OUT, encoding="utf-8"))
    print(f"已有 {len(covers)} 个封面映射，断点续抓", flush=True)

    total = 0
    first = fetch(BASE + "/girl?p=1") or ""
    m = re.search(r"共\s*(\d+)\s*位", re.sub(r"<[^>]+>", "", first))
    if m:
        total = int(m.group(1))
    pages = (total // 25) + 3 if total else 500
    for page in range(1, pages + 1):
        text = first if page == 1 else fetch(f"{BASE}/girl?p={page}")
        if not text:
            break
        new = 0
        for gid, url, _aid in CARD_RE.findall(text):
            if gid not in covers:
                covers[gid] = "https:" + url
                new += 1
        if page % 40 == 0:
            print(f"  列表第 {page}/{pages} 页，累计 {len(covers)} 个封面", flush=True)
            json.dump(covers, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
        if new == 0 and page > 2:
            # 连续无新增说明列表循环到尾部；再探一页确认
            nxt = fetch(f"{BASE}/girl?p={page + 1}") or ""
            if not CARD_RE.search(nxt) or all(
                    gid in covers for gid, _u, _a in CARD_RE.findall(nxt)):
                break
        time.sleep(0.25)
    json.dump(covers, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"封面映射完成：{len(covers)} 个 → {OUT}", flush=True)

    data = json.load(open(TARGET, encoding="utf-8"))
    updated = kept = missing = 0
    for record in data:
        m = re.search(r"/girl/(\d+)$", record.get("source_url") or "")
        if not m:
            continue
        cover = covers.get(m.group(1))
        if cover:
            if record.get("image_url") != cover:
                record["image_url"] = cover
                updated += 1
            else:
                kept += 1
        else:
            record["image_url"] = None
            missing += 1
    tmp = TARGET + ".tmp"
    json.dump(data, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, TARGET)
    print(f"image_url 更新 {updated}、原值正确 {kept}、未找到封面置空 {missing}")


if __name__ == "__main__":
    main()
