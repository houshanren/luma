#!/usr/bin/env python3
"""GRAPHIS（graphis.ne.jp）月度模特档案：年齢 / 身長 / 三围 / 趣味 / 简介 / 头像。

结构：
- 列表页 /monthly/index.php?P=<0 起页>&MC=<1..6>&RM=<1..3>，每页 30 位模特，
  超出返回没有模特的空页。
- 详情页 /monthly/model.php?ID=<YYMMDD_罗马字>，Profile 区块是 <li><span>字段</span><span>值</span></li>。
- 头像 https://data.graphis.ne.jp/free/model/{ID}/prof.jpg（360×508 竖图），
  model.jpg 是 1185×835 横图，作为兜底。

同一个模特会以多次登场出现在不同 ID 下（如 小花のん 有 4 个 ID），
按「日文名」合并，字段取最新一次登场（ID 前缀就是日期），登场次数取最大值。

只取文字与头像 URL，不下载图片。输出 raw/jp_profiles_graphis.json，
build_catalog_db.py 里按 require_existing 只补已有条目（避免与 R18 罗马字
人名撞车时新建重复人物）。

用法：
    python3 Tools/catalog_build/fetch/fetch_graphis.py
    GRAPHIS_MAX_PAGES=1 python3 Tools/catalog_build/fetch/fetch_graphis.py   # 小样
"""

from __future__ import annotations

import concurrent.futures
import html
import json
import os
import re
import time

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
CACHE = os.path.join(RAW, ".graphis")
OUT = os.path.join(RAW, "jp_profiles_graphis.json")

BASE = "https://graphis.ne.jp"
HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"),
    "Accept-Language": "ja,en;q=0.8",
}
WORKERS = 4
MAX_PAGES = int(os.environ.get("GRAPHIS_MAX_PAGES") or 40)

MODEL_LINK = re.compile(r'href="(/monthly/model\.php\?ID=([^"]+))"[^>]*>\s*'
                        r'<div class="user-rank-tag"></div>\s*<img src="([^"]+)" alt="([^"]*)"')
PAN_LINK = re.compile(r'<p class="pan-link">(.*?)</p>', re.S)
INFO_ITEM = re.compile(r"<li><span>([^<]+)</span><span>(.*?)</span></li>", re.S)
COMMENT_JP = re.compile(r'<li class="text-jp">(.*?)</li>', re.S)

AGE_RE = re.compile(r"(\d+)")
HEIGHT_RE = re.compile(r"(\d{2,3})")
BWH_RE = re.compile(r"B(\d{2,3})\s*(?:\(([A-Z])\))?\s*W(\d{2,3})\s*H(\d{2,3})")
SHOTS_RE = re.compile(r"(\d+)")

TAG_RE = re.compile(r"<[^>]+>")


def text_of(value: str) -> str:
    """去标签、压空白；<br> 保留为换行（日英对照的字段只取日文一行）。"""
    value = re.sub(r"<br\s*/?>", "\n", value or "")
    value = TAG_RE.sub("", value)
    lines = [re.sub(r"\s+", " ", html.unescape(line)).strip() for line in value.split("\n")]
    return "\n".join(line for line in lines if line)


def fetch(url: str, cache_name: str) -> str | None:
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, cache_name)
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="ignore") as handle:
            return handle.read()
    for attempt in range(3):
        try:
            response = requests.get(url, headers=HEADERS, timeout=25)
            if response.status_code == 404:
                return None
            if response.status_code != 200:
                time.sleep(1.5 + 2 * attempt)
                continue
            response.encoding = response.apparent_encoding or "utf-8"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(response.text)
            time.sleep(0.3)
            return response.text
        except Exception:  # noqa: BLE001 - 单页失败重试
            time.sleep(1.5 * (attempt + 1))
    return None


def parse_list(page: str):
    """列表页 → [(ID, 列表缩略图)]。"""
    return [(match.group(2), match.group(3)) for match in MODEL_LINK.finditer(page)]


def parse_detail(page: str, model_id: str, fallback_name: str):
    info = {}
    for label, value in INFO_ITEM.findall(page):
        # 标签形如「身長 /height：」，去掉结尾冒号再查。
        info[text_of(label).rstrip("：: ")] = text_of(value)
    name, aliases = fallback_name, []
    pan = PAN_LINK.search(page)
    if pan:
        # 「TOP > モデル一覧/Models > 小花のん/Non Ohana」→ 最后一段
        parts = [text_of(part) for part in re.split(r"&gt;|>", pan.group(1))]
        if parts:
            last = parts[-1]
            if "/" in last:
                jp, en = last.split("/", 1)
                name, aliases = jp.strip(), [en.strip()]
            elif last:
                name = last
    if not name:
        return None
    height = AGE_RE.search(info.get("身長 /height", ""))
    bwh = BWH_RE.search(info.get("スリーサイズ /BWH", ""))
    shots = SHOTS_RE.search(info.get("登場回数 /Number of shots", ""))
    comment = COMMENT_JP.search(page)
    image = f"https://data.graphis.ne.jp/free/model/{model_id}/prof.jpg"
    return {
        "name": name,
        "aliases": [alias for alias in aliases if alias and alias != name],
        "region": "japan",
        "height": int(height.group(1)) if height else None,
        "bust": int(bwh.group(1)) if bwh else None,
        "cup": bwh.group(2) if bwh and bwh.group(2) else None,
        "waist": int(bwh.group(3)) if bwh else None,
        "hips": int(bwh.group(4)) if bwh else None,
        "hobby": (info.get("趣味 /hobby") or "").split("\n")[0] or None,
        "summary": text_of(comment.group(1)) if comment else None,
        "image_url": image,
        "album_count": int(shots.group(1)) if shots else None,
        "source": "graphis",
        "source_url": f"{BASE}/monthly/model.php?ID={model_id}",
        "require_existing": True,
        "_id": model_id,
    }


def discover():
    """翻遍 RM×MC 的所有列表页，返回 {ID: 列表缩略图}。"""
    found: dict[str, str] = {}
    pages = 0
    for rm in range(1, 4):
        for mc in range(1, 7):
            for page_no in range(MAX_PAGES):
                cache_name = f"list_{rm}_{mc}_{page_no}.html"
                url = f"{BASE}/monthly/index.php?P={page_no}&MC={mc}&RM={rm}"
                page = fetch(url, cache_name)
                if not page:
                    break
                items = parse_list(page)
                if not items:
                    break
                for model_id, thumb in items:
                    found.setdefault(model_id, thumb)
                pages += 1
                if page_no == 0 and pages % 6 == 0:
                    print(f"  列表页已翻 {pages} 页，模特登场 {len(found)} 条", flush=True)
    print(f"  列表页 {pages} 页，共 {len(found)} 次登场", flush=True)
    return found


def main():
    models = discover()
    if not models:
        print("没有拿到任何模特，检查网络")
        return
    ids = sorted(models)
    results = []
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {
            pool.submit(fetch, f"{BASE}/monthly/model.php?ID={model_id}",
                        f"model_{model_id}.html"): model_id
            for model_id in ids
        }
        for future in concurrent.futures.as_completed(futures):
            model_id = futures[future]
            done += 1
            try:
                page = future.result()
            except Exception:  # noqa: BLE001
                page = None
            if page:
                row = parse_detail(page, model_id, "")
                if row:
                    results.append(row)
            if done % 20 == 0:
                print(f"  详情 {done}/{len(ids)}，可用 {len(results)}", flush=True)

    # 同一个人多次登场：ID 前缀是 YYMMDD，取最新一次的字段，登场次数取最大。
    merged: dict[str, dict] = {}
    for row in sorted(results, key=lambda item: item["_id"]):
        name = row["name"]
        current = merged.get(name)
        if current is None:
            merged[name] = row
            continue
        if row["_id"] > current["_id"]:
            row["album_count"] = max(row.get("album_count") or 0,
                                     current.get("album_count") or 0)
            merged[name] = row
        else:
            current["album_count"] = max(row.get("album_count") or 0,
                                         current.get("album_count") or 0)

    rows = list(merged.values())
    for row in rows:
        row.pop("_id", None)
    rows.sort(key=lambda item: item["name"])
    os.makedirs(RAW, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=1)
    with_image = sum(1 for row in rows if row.get("image_url"))
    with_size = sum(1 for row in rows if row.get("bust"))
    print(f"完成 {len(rows)} 人（有头像 {with_image}，有三围 {with_size}）→ {OUT}",
          flush=True)


if __name__ == "__main__":
    main()
