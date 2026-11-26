#!/usr/bin/env python3
"""把 R18.dev 的 PostgreSQL 全量 dump 压成 App 建库可用的 JSON。

R18.dev 每周二更新 CC0 dump（gzip 的 pg_dump SQL，约 278MB / 解压 1.5GB）：
- derived_video            192.4 万部作品
- derived_actress          10.2 万位女优
- derived_video_actress    250.7 万条作品↔女优
- derived_video_category   962.6 万条作品↔分类
- derived_maker/label/series/director 等元数据

直接全量入库会让 App 内置库翻几倍，所以这里做三件事：
1. 流式解析 COPY 块，把需要的表落到 raw/r18/r18.sqlite 缓存（只在没有缓存时跑一次）；
2. 用当前 catalog.sqlite 的主名/别名把 R18 女优匹配到库内人物，只有匹配上的作品才导出；
3. 导出 raw/r18_actresses.json（补 R18 ID / 头像 / 假名别名）与
   raw/r18_videos.json（作品 + 分类 + 厂牌 + 封面，按人截取最近 N 部）。

用法：
    python3 Tools/catalog_build/import_r18_dump.py            # 解析 + 导出
    python3 Tools/catalog_build/import_r18_dump.py --stats    # 只看规模和匹配率
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sqlite3
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
R18_DIR = os.path.join(RAW, "r18")
CATALOG = os.path.join(ROOT, "Resources", "Catalog", "catalog.sqlite")
CACHE_DB = os.path.join(R18_DIR, "r18.sqlite")
OUT_ACTRESSES = os.path.join(RAW, "r18_actresses.json")
OUT_VIDEOS = os.path.join(RAW, "r18_videos.json")
DEFAULT_DUMP = os.path.join(R18_DIR, "r18dotdev_dump_2026-11-24.sql.gz")

# 只保留建库用得到的表；列顺序与 dump 里的 COPY 头一致。
TABLES = {
    "derived_actress": ["id", "name_romaji", "image_url", "name_kanji", "name_kana"],
    "derived_video": [
        "content_id", "dvd_id", "title_en", "title_ja", "comment_en", "comment_ja",
        "runtime_mins", "release_date", "sample_url", "maker_id", "label_id",
        "series_id", "jacket_full_url", "jacket_thumb_url", "gallery_full_first",
        "gallery_full_last", "gallery_thumb_first", "gallery_thumb_last",
        "site_id", "service_code",
    ],
    "derived_video_actress": ["content_id", "actress_id", "ordinality", "release_date"],
    "derived_video_category": ["content_id", "category_id", "release_date"],
    "derived_category": ["id", "name_en", "name_ja"],
    "derived_maker": ["id", "name_en", "name_ja"],
    "derived_label": ["id", "name_en", "name_ja"],
    "derived_series": ["id", "name_en", "name_ja"],
}

COPY_HEAD = re.compile(r"^COPY public\.(\w+) \(([^)]*)\) FROM stdin;$")
ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "b": "\b", "f": "\f", "v": "\v",
           "\\": "\\", "N": None}


def unescape(value: str):
    """还原 PostgreSQL COPY 文本格式的转义（\\t / \\n / \\\\ / \\xHH / 八进制）。"""
    if value == r"\N":
        return None
    if "\\" not in value:
        return value
    out = []
    index = 0
    length = len(value)
    while index < length:
        char = value[index]
        if char != "\\" or index + 1 >= length:
            out.append(char)
            index += 1
            continue
        nxt = value[index + 1]
        if nxt in ESCAPES:
            mapped = ESCAPES[nxt]
            if mapped is None:
                return None
            out.append(mapped)
            index += 2
        elif nxt == "x" and index + 3 < length:
            try:
                out.append(chr(int(value[index + 2:index + 4], 16)))
            except ValueError:
                out.append(nxt)
            index += 4
        elif nxt in "01234567":
            digits = value[index + 1:index + 4]
            match = re.match(r"[0-7]{1,3}", digits)
            out.append(chr(int(match.group(0), 8)))
            index += 1 + len(match.group(0))
        else:
            out.append(nxt)
            index += 2
    return "".join(out)


def parse_dump(dump_path: str) -> None:
    """流式解析 dump，把需要的表写进 r18.sqlite。"""
    os.makedirs(R18_DIR, exist_ok=True)
    if os.path.exists(CACHE_DB):
        os.remove(CACHE_DB)
    connection = sqlite3.connect(CACHE_DB)
    connection.executescript(
        "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;")
    table = None
    columns: list[str] = []
    batch: list[tuple] = []

    def flush():
        if batch and table:
            placeholders = ",".join("?" * len(columns))
            connection.executemany(
                f"INSERT INTO {table} VALUES ({placeholders})", batch)
            batch.clear()

    print(f"解析 {os.path.basename(dump_path)} …", flush=True)
    with gzip.open(dump_path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if table is None:
                match = COPY_HEAD.match(line)
                if match and match.group(1) in TABLES:
                    table = match.group(1)
                    columns = [name.strip() for name in match.group(2).split(",")]
                    connection.execute(
                        f"CREATE TABLE {table} ({','.join(name + ' TEXT' for name in columns)})")
                    batch.clear()
                continue
            if line.startswith("\\."):
                flush()
                table = None
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != len(columns):
                continue
            batch.append(tuple(unescape(field) for field in fields))
            if len(batch) >= 50000:
                flush()
    connection.commit()
    connection.executescript(
        """
        CREATE INDEX idx_va_actress ON derived_video_actress(actress_id);
        CREATE INDEX idx_va_content ON derived_video_actress(content_id);
        CREATE INDEX idx_vc_content ON derived_video_category(content_id);
        CREATE INDEX idx_video_dvd ON derived_video(dvd_id);
        CREATE INDEX idx_video_date ON derived_video(release_date);
        """)
    connection.commit()
    connection.close()
    print("缓存完成：", CACHE_DB, flush=True)


def normalize_names(names: list[str]) -> list[str]:
    """与建库脚本一致：Foundation 繁简转换 + 日文异体字 + 去标点小写。"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from build_catalog_db import normalize_all
    chunk = 60000
    result: list[str] = []
    for start in range(0, len(names), chunk):
        result.extend(normalize_all(names[start:start + chunk]))
    return result


def load_catalog_names() -> dict[str, set[tuple[int, str]]]:
    """库内人名/别名 → {(人物 id, 地区)}。"""
    connection = sqlite3.connect(CATALOG)
    rows = connection.execute("SELECT id, name, region, aliases FROM actresses").fetchall()
    connection.close()
    flat: list[str] = []
    owners: list[tuple[int, str]] = []
    for rid, name, region, aliases_json in rows:
        names = [name]
        try:
            names.extend(json.loads(aliases_json or "[]"))
        except (ValueError, TypeError):
            pass
        for candidate in names:
            if candidate:
                flat.append(candidate)
                owners.append((rid, region or "japan"))
    keys = normalize_names(flat)
    mapping: dict[str, set[tuple[int, str]]] = {}
    for key, owner in zip(keys, owners):
        if key:
            mapping.setdefault(key, set()).add(owner)
    return mapping


def match_actresses(mapping: dict[str, set[tuple[int, str]]]) -> dict[int, dict]:
    """R18 女优 → 库内人物（唯一命中才算；多命中优先日本区）。"""
    connection = sqlite3.connect(CACHE_DB)
    rows = connection.execute(
        "SELECT id, name_romaji, image_url, name_kanji, name_kana FROM derived_actress").fetchall()
    connection.close()
    flat: list[str] = []
    spans: list[tuple[int, str, int]] = []  # (r18 id, 候选名, 名称类型)
    for rid, romaji, image, kanji, kana in rows:
        for kind, value in (("kanji", kanji), ("kana", kana), ("romaji", romaji)):
            if value and value.strip() and value.strip() != "----":
                flat.append(value.strip())
                spans.append((rid, kind, len(flat) - 1))
    keys = normalize_names(flat)
    hits: dict[int, dict] = {}
    for r18_id, kind, index in spans:
        key = keys[index]
        owners = mapping.get(key)
        if not owners:
            continue
        ids = {owner for owner, _ in owners}
        if len(ids) > 1:
            japan = {owner for owner, region in owners if region == "japan"}
            if len(japan) != 1:
                continue
            owner_id = next(iter(japan))
            region = "japan"
        else:
            owner_id = next(iter(ids))
            region = next(iter(owners))[1]
        entry = hits.setdefault(r18_id, {"person_id": owner_id, "region": region,
                                         "names": [], "image": None})
        if flat[index] not in entry["names"]:
            entry["names"].append(flat[index])
    return hits


def full_image(value: str | None) -> str | None:
    if not value or value in ("null", "----"):
        return None
    if value.startswith("http"):
        return value
    return f"https://pics.dmm.co.jp/mono/actjpgs/{value}" + ("" if value.endswith(".jpg") else ".jpg")


def full_jacket(value: str | None) -> str | None:
    if not value:
        return None
    if value.startswith("http"):
        return value
    return f"https://pics.dmm.co.jp/{value}" + ("" if value.endswith(".jpg") else ".jpg")


def stats(hits: dict[int, dict]) -> None:
    connection = sqlite3.connect(CACHE_DB)
    total_videos = connection.execute("SELECT COUNT(*) FROM derived_video").fetchone()[0]
    with_jacket = connection.execute(
        "SELECT COUNT(*) FROM derived_video WHERE jacket_full_url IS NOT NULL").fetchone()[0]
    years = connection.execute(
        "SELECT substr(release_date,1,4), COUNT(*) FROM derived_video "
        "WHERE release_date IS NOT NULL GROUP BY 1 ORDER BY 1 DESC LIMIT 8").fetchall()
    connection.close()
    matched_ids = {entry["person_id"] for entry in hits.values()}
    print(f"匹配到库内人物：{len(hits):,} 位 R18 女优 / {len(matched_ids):,} 位库内人物")
    print(f"作品总数 {total_videos:,}，有封面 {with_jacket:,}")
    print("最近年份分布：", years)


def export(hits: dict[int, dict], per_actress: int) -> None:
    connection = sqlite3.connect(CACHE_DB)
    connection.row_factory = sqlite3.Row
    # 1) 女优补丁：R18 ID + 头像 + 假名/罗马字别名
    actress_rows = []
    matched_ids = sorted(hits)
    for start in range(0, len(matched_ids), 900):
        chunk = matched_ids[start:start + 900]
        rows = connection.execute(
            f"SELECT * FROM derived_actress WHERE id IN ({','.join('?' * len(chunk))})",
            chunk).fetchall()
        for row in rows:
            entry = hits[row["id"]]
            names = [name for name in entry["names"]]
            actress_rows.append({
                "r18_id": str(row["id"]),
                "person_id": entry["person_id"],
                "region": entry["region"],
                "names": names,
                "image": full_image(row["image_url"]),
                "name_kanji": row["name_kanji"],
                "name_kana": row["name_kana"],
                "name_romaji": row["name_romaji"],
            })
    with open(OUT_ACTRESSES, "w", encoding="utf-8") as handle:
        json.dump(actress_rows, handle, ensure_ascii=False)
    print(f"写出 {OUT_ACTRESSES}：{len(actress_rows)} 位", flush=True)

    # 2) 作品：按人物截取最近 N 部（同一部多人参演只导出一次）
    caps = {rid: per_actress for rid in matched_ids}
    remaining = sum(caps.values())
    picked: dict[str, None] = {}
    placeholders = ",".join("?" * len(matched_ids))
    cursor = connection.execute(
        f"""SELECT va.content_id, va.actress_id
            FROM derived_video_actress va
            JOIN derived_video v ON v.content_id = va.content_id
            WHERE va.actress_id IN ({placeholders})
              AND v.jacket_full_url IS NOT NULL AND v.release_date IS NOT NULL
            ORDER BY v.release_date DESC""", matched_ids)
    for content_id, actress_id in cursor:
        if content_id in picked or caps.get(actress_id, 0) <= 0:
            continue
        caps[actress_id] -= 1
        remaining -= 1
        picked[content_id] = None
        if remaining <= 0:
            break
    print(f"选中作品 {len(picked):,} 部", flush=True)

    # 参演名单单独按 content_id 查，避免截断时漏掉同一部里靠后的共演者。
    actress_map: dict[str, list[str]] = {}
    for start in range(0, len(picked), 900):
        chunk = list(picked)[start:start + 900]
        for row in connection.execute(
                f"SELECT content_id, actress_id FROM derived_video_actress "
                f"WHERE content_id IN ({','.join('?' * len(chunk))})", chunk):
            entry = hits.get(row["actress_id"])
            if not entry or not entry["names"]:
                continue
            names = actress_map.setdefault(row["content_id"], [])
            if entry["names"][0] not in names:
                names.append(entry["names"][0])

    categories = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
                  for row in connection.execute("SELECT * FROM derived_category")}
    makers = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_maker")}
    labels = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_label")}
    series = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_series")}

    content_ids = list(picked)
    genres: dict[str, list[str]] = {}
    for start in range(0, len(content_ids), 900):
        chunk = content_ids[start:start + 900]
        for row in connection.execute(
                f"SELECT content_id, category_id FROM derived_video_category "
                f"WHERE content_id IN ({','.join('?' * len(chunk))})", chunk):
            name = categories.get(str(row["category_id"]))
            if name:
                genres.setdefault(row["content_id"], []).append(name)

    videos = []
    for start in range(0, len(content_ids), 900):
        chunk = content_ids[start:start + 900]
        for row in connection.execute(
                f"SELECT * FROM derived_video WHERE content_id IN ({','.join('?' * len(chunk))})",
                chunk):
            dvd_id = (row["dvd_id"] or "").strip()
            if not dvd_id:
                continue
            videos.append({
                "content_id": row["content_id"],
                "dvd_id": dvd_id,
                "title_ja": row["title_ja"],
                "title_en": row["title_en"],
                "release_date": row["release_date"],
                "runtime": row["runtime_mins"],
                "maker": makers.get(str(row["maker_id"])),
                "label": labels.get(str(row["label_id"])),
                "series": series.get(str(row["series_id"])),
                "genres": genres.get(row["content_id"], []),
                "cover": full_jacket(row["jacket_full_url"]),
                "trailer": row["sample_url"],
                "actresses": actress_map.get(row["content_id"], []),
            })
    connection.close()
    videos.sort(key=lambda item: item["release_date"] or "", reverse=True)
    # 同一 dvd_id 可能有多个 content_id（普通版 / BOD 版 / 特典版），只保留最新那条。
    unique = []
    seen_dvd = set()
    for item in videos:
        key = item["dvd_id"].casefold()
        if key in seen_dvd:
            continue
        seen_dvd.add(key)
        unique.append(item)
    videos = unique
    with open(OUT_VIDEOS, "w", encoding="utf-8") as handle:
        json.dump(videos, handle, ensure_ascii=False)
    print(f"写出 {OUT_VIDEOS}：{len(videos):,} 部，"
          f"{os.path.getsize(OUT_VIDEOS) / 1_000_000:.1f} MB", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump", default=DEFAULT_DUMP)
    parser.add_argument("--per-actress", type=int, default=30,
                        help="每位女优最多导出最近多少部作品")
    parser.add_argument("--stats", action="store_true", help="只打印规模与匹配率")
    args = parser.parse_args()
    if not os.path.exists(CACHE_DB):
        if not os.path.exists(args.dump):
            raise SystemExit(f"没有 dump 也没有缓存：{args.dump}")
        parse_dump(args.dump)
    mapping = load_catalog_names()
    print(f"库内名字键 {len(mapping):,} 个", flush=True)
    hits = match_actresses(mapping)
    stats(hits)
    if not args.stats:
        export(hits, args.per_actress)


if __name__ == "__main__":
    main()
