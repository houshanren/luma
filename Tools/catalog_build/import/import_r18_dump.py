#!/usr/bin/env python3
"""把 R18.dev 的 PostgreSQL 全量 dump 压成 App 建库可用的 JSON。

R18.dev 每周二更新 CC0 dump（gzip 的 pg_dump SQL，约 278MB / 解压 1.5GB）：
- derived_video            192.4 万部作品
- derived_actress          10.2 万位女优
- derived_video_actress    250.7 万条作品↔女优
- derived_video_category   962.6 万条作品↔分类
- derived_director / derived_video_director   导演与作品↔导演
- source_dmm_video_histrion   DMM 演员 id ↔ 作品（用来给女优补 DMM 演员 ID）
- derived_maker/label/series/site 等元数据

直接全量入库会让 App 内置库翻几倍，所以这里做三件事：
1. 流式解析 COPY 块，把需要的表落到 raw/r18/r18.sqlite 缓存（只在没有缓存时跑一次）；
2. 用当前 catalog.sqlite 的主名/别名/括号别名把 R18 女优匹配到库内人物；匹配不上的
   按名字去重建档（库内已有的名字一律视为同一个人，不重复新建）；
3. 导出 raw/r18_actresses.json（R18 ID / DMM ID / 头像 / 假名别名）与
   raw/r18_videos.json（已在库女优导出全字段；新建档女优只导番号 / 标题 / 日期 / 封面）。

用法：
    python3 Tools/catalog_build/import/import_r18_dump.py            # 复用缓存解析 + 导出（含新人建档）
    python3 Tools/catalog_build/import/import_r18_dump.py --stats    # 只看规模和匹配率
    python3 Tools/catalog_build/import/import_r18_dump.py --refresh  # 换新 dump 后强制重新解析
    python3 Tools/catalog_build/import/import_r18_dump.py --existing-only   # 只补已有女优，不建新档
    python3 Tools/catalog_build/import/import_r18_dump.py --per-actress 0   # 每人全量作品
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

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
R18_DIR = os.path.join(RAW, "r18")
CATALOG = os.path.join(ROOT, "Resources", "Catalog", "catalog.sqlite")
CACHE_DB = os.path.join(R18_DIR, "r18.sqlite")
OUT_ACTRESSES = os.path.join(RAW, "r18_actresses.json")
OUT_VIDEOS = os.path.join(RAW, "r18_videos.json")
DEFAULT_DUMP = os.path.join(R18_DIR, "r18dotdev_dump_2026-11-24.sql.gz")

# 只保留建库用得到的表；列全部按 dump 的 COPY 头自动建（值里的清单只是文档）。
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
    # 导演：derived_director 是名字表，derived_video_director 是作品↔导演。
    "derived_director": ["id", "name_kanji", "name_kana", "name_romaji"],
    "derived_video_director": ["content_id", "director_id"],
    # 站点（DMM / FANZA / MGS…），作品表里的 site_id 指向它。
    "derived_site": ["id", "name"],
    # DMM 演员 id ↔ 作品：用来给 R18 女优补 DMM 演员 ID（只取一对一的作品，避免男女串号）。
    "source_dmm_video_histrion": ["histrion_id", "timestamp", "content_id"],
}

COPY_HEAD = re.compile(r"^COPY public\.(\w+) \(([^)]*)\) FROM stdin;$")
CONTROL = re.compile(r"[\r\n\t]+")
ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "b": "\b", "f": "\f", "v": "\v",
           "\\": "\\", "N": None}


def clean(value):
    """R18 名字/标题里偶发换行（一个字段里塞两行），压成空格再比对。"""
    if value is None:
        return None
    return CONTROL.sub(" ", value).strip()


def squash(value):
    """比对用的名字：清理空值占位再压空白。"""
    text = clean(value)
    if not text or text in ("----", "null", "None"):
        return ""
    return text


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
        CREATE INDEX idx_vd_content ON derived_video_director(content_id);
        CREATE INDEX idx_dmmh_content ON source_dmm_video_histrion(content_id);
        CREATE INDEX idx_dmmh_histrion ON source_dmm_video_histrion(histrion_id);
        """)
    connection.commit()
    connection.close()
    print("缓存完成：", CACHE_DB, flush=True)


def normalize_names(names: list[str]) -> list[str]:
    """与建库脚本一致：Foundation 繁简转换 + 日文异体字 + 去标点小写。"""
    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build"))
    from build_catalog_db import normalize_all
    chunk = 60000
    result: list[str] = []
    for start in range(0, len(names), chunk):
        result.extend(normalize_all(names[start:start + chunk]))
    if len(result) != len(names):
        raise RuntimeError(f"名字归一后数量不一致：{len(names)} → {len(result)}")
    return result


def load_catalog_names() -> tuple[dict[str, set[tuple[int, str]]], set[int]]:
    """库内人名 / 别名 → {(人物 id, 地区)}，外加「只由 R18 建档」的人物 id。

    重复跑时不能把上一轮 R18 建的人物当成「库内已有」：否则第一次导出 4 万新人，
    第二次全部匹配上，就把精简作品升级成全字段，越跑越膨胀。
    """
    connection = sqlite3.connect(CATALOG)
    rows = connection.execute(
        "SELECT id, name, region, aliases, source FROM actresses").fetchall()
    connection.close()
    flat: list[str] = []
    owners: list[tuple[int, str]] = []
    r18_only: set[int] = set()
    for rid, name, region, aliases_json, source in rows:
        if (source or "") == "r18":
            r18_only.add(rid)
        names = [name]
        try:
            names.extend(json.loads(aliases_json or "[]"))
        except (ValueError, TypeError):
            pass
        for candidate in names:
            text = clean(candidate)
            if text:
                flat.append(text)
                owners.append((rid, region or "japan"))
    keys = normalize_names(flat)
    mapping: dict[str, set[tuple[int, str]]] = {}
    for key, owner in zip(keys, owners):
        if key:
            mapping.setdefault(key, set()).add(owner)
    return mapping, r18_only


def match_actresses(mapping: dict[str, set[tuple[int, str]]],
                    r18_only: set[int]) -> dict[int, dict]:
    """R18 女优 → 库内人物（唯一命中才算；多命中优先日本区）。"""
    connection = sqlite3.connect(CACHE_DB)
    rows = connection.execute(
        "SELECT id, name_romaji, image_url, name_kanji, name_kana FROM derived_actress").fetchall()
    connection.close()
    flat: list[str] = []
    spans: list[tuple[int, str, int]] = []  # (r18 id, 名称类型, flat 下标)
    for rid, romaji, image, kanji, kana in rows:
        for kind, value in (("kanji", kanji), ("kana", kana), ("romaji", romaji)):
            text = squash(value)
            if text:
                flat.append(text)
                spans.append((rid, kind, len(flat) - 1))
    keys = normalize_names(flat)
    hits: dict[int, dict] = {}
    for r18_id, kind, index in spans:
        key = keys[index]
        # R18 是日本女优库：只接受库内日本区的人，避免「Rin」「Ako」这类
        # 罗马字撞到欧美同名条目。只由 R18 建的人物不算「库内既有」。
        owners = {owner for owner in mapping.get(key) or ()
                  if owner[1] == "japan" and owner[0] not in r18_only}
        if len({owner for owner, _ in owners}) != 1:
            continue
        owner_id = next(iter(owners))[0]
        entry = hits.setdefault(r18_id, {"person_id": owner_id, "region": "japan",
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


def stats(hits: dict[int, dict], dmm_ids: dict[str, str]) -> None:
    connection = sqlite3.connect(CACHE_DB)
    total_videos = connection.execute("SELECT COUNT(*) FROM derived_video").fetchone()[0]
    with_jacket = connection.execute(
        "SELECT COUNT(*) FROM derived_video WHERE jacket_full_url IS NOT NULL").fetchone()[0]
    with_thumb = connection.execute(
        "SELECT COUNT(*) FROM derived_video WHERE jacket_thumb_url IS NOT NULL").fetchone()[0]
    with_comment = connection.execute(
        "SELECT COUNT(*) FROM derived_video "
        "WHERE comment_ja IS NOT NULL OR comment_en IS NOT NULL").fetchone()[0]
    with_gallery = connection.execute(
        "SELECT COUNT(*) FROM derived_video WHERE gallery_thumb_first IS NOT NULL").fetchone()[0]
    with_director = connection.execute(
        "SELECT COUNT(DISTINCT content_id) FROM derived_video_director").fetchone()[0]
    with_trailer = connection.execute(
        "SELECT COUNT(*) FROM derived_video WHERE sample_url IS NOT NULL").fetchone()[0]
    years = connection.execute(
        "SELECT substr(release_date,1,4), COUNT(*) FROM derived_video "
        "WHERE release_date IS NOT NULL GROUP BY 1 ORDER BY 1 DESC LIMIT 8").fetchall()
    connection.close()
    matched_ids = {entry["person_id"] for entry in hits.values()}
    print(f"匹配到库内人物：{len(hits):,} 位 R18 女优 / {len(matched_ids):,} 位库内人物")
    print(f"作品总数 {total_videos:,}：封面 {with_jacket:,} / 缩略图 {with_thumb:,} / "
          f"简介 {with_comment:,} / 剧照 {with_gallery:,} / 导演 {with_director:,} / "
          f"试看 {with_trailer:,}")
    print(f"DMM 演员 ID 映射：{len(dmm_ids):,} 位 R18 女优")
    print("最近年份分布：", years)


def dmm_histrion_ids(connection) -> dict[str, str]:
    """R18 actress_id → DMM 演员 id（补 external_ids 用）。

    只用「作品恰好 1 位女优 + 恰好 1 位 DMM 演员」的作品投票：共演作品
    和男优同片都会让内容对上多个 DMM 演员，一律跳过；再要求同一映射在
    至少 2 部作品里重复、且占该女优一对一作品的大多数，避免串号。
    """
    rows = connection.execute(
        """
        WITH one_actress AS (
            SELECT content_id, MIN(actress_id) AS actress_id
            FROM derived_video_actress GROUP BY content_id HAVING COUNT(*) = 1
        ), one_histrion AS (
            SELECT content_id, MIN(histrion_id) AS histrion_id
            FROM source_dmm_video_histrion GROUP BY content_id HAVING COUNT(*) = 1
        )
        SELECT a.actress_id, h.histrion_id, COUNT(*) AS n
        FROM one_actress a JOIN one_histrion h ON a.content_id = h.content_id
        GROUP BY a.actress_id, h.histrion_id
        """).fetchall()
    best: dict[str, tuple[str, int]] = {}
    total: dict[str, int] = {}
    for actress_id, histrion_id, count in rows:
        actress_key = str(actress_id)
        total[actress_key] = total.get(actress_key, 0) + count
        current = best.get(actress_key)
        if current is None or count > current[1]:
            best[actress_key] = (str(histrion_id), count)
    result = {}
    for actress_key, (histrion_id, count) in best.items():
        if count >= 2 and count / max(total[actress_key], 1) >= 0.6:
            result[actress_key] = histrion_id
    return result


def split_names(value: str | None) -> list[str]:
    """R18 会把别名塞进一个字段（「A（B、C）」），拆成独立候选名再比对。

    不拆的话，库里已有的「羽生アリサ」会因为 R18 写成「羽生アリサ（羽生ありさ）」
    而匹配不上，白白新建一条重复人物。
    """
    text = squash(value)
    if not text:
        return []
    parts = re.split(r"[（）()【】\[\]、,，／/＆&;；|]", text)
    return [part.strip() for part in parts if part.strip()]


def collect_new_actresses(connection, mapping, r18_only, hits, dmm_ids):
    """未匹配的 R18 女优：与库内名字去重后建档（只留名字 / 头像 / R18 ID）。

    「以当前库为准」：任一名字变体（汉字 / 假名 / 罗马字，含括号里的别名）命中
    **非 R18 来源**的库内人物，就视为已有人物，不新建；只命中上一轮 R18 建档的人物
    则复用（不重复建人），这样重复跑不会把精简作品一路升级成全字段。
    """
    rows = connection.execute(
        "SELECT id, name_romaji, image_url, name_kanji, name_kana "
        "FROM derived_actress ORDER BY id").fetchall()
    # 库内「非 R18」的名字键：命中即跳过；只命中 R18 建档的人则复用。
    core_keys = {key for key, owners in mapping.items()
                 if any(owner[0] not in r18_only for owner in owners)}
    owners: dict[str, dict] = {}
    groups: list[dict] = []
    skipped_collision = 0
    skipped_empty = 0
    # 先把所有候选名收集起来一次归一（normalize_names 每次会起一个 Swift 进程，
    # 逐行调用会把 8 万位女优拖成几小时）。
    prepared = []
    flat = []
    for r18_id, romaji, image, kanji, kana in rows:
        if r18_id in hits:
            continue
        mains = {}
        names = []
        for field, value in (("name_kanji", kanji), ("name_kana", kana),
                             ("name_romaji", romaji)):
            parts = split_names(value)
            mains[field] = parts[0] if parts else None
            for part in parts:
                if part not in names:
                    names.append(part)
        prepared.append((r18_id, image, names, mains))
        flat.extend(names)
    normalized = normalize_names(flat) if flat else []
    cursor = 0
    for r18_id, image, names, mains in prepared:
        keys = normalized[cursor:cursor + len(names)]
        cursor += len(names)
        keys = [key for key in keys if len(key) >= 2]
        if not names or not keys:
            skipped_empty += 1
            continue
        if any(key in core_keys for key in keys):
            skipped_collision += 1
            continue
        group = next((owners[key] for key in keys if key in owners), None)
        if group is None:
            group = {
                "names": [],
                "name_kanji": None,
                "name_kana": None,
                "name_romaji": None,
                "image": None,
                "r18_ids": [],
                "dmm_id": None,
                # 上一轮已经建过（只命中 R18 来源的人），本轮只复用，不新建。
                "existing": any(key in mapping for key in keys),
            }
            groups.append(group)
        for field in ("name_kanji", "name_kana", "name_romaji"):
            if mains.get(field) and not group[field]:
                group[field] = mains[field]
        for name in names:
            if name not in group["names"]:
                group["names"].append(name)
        if not group["image"]:
            group["image"] = full_image(image)
        if not group["dmm_id"]:
            group["dmm_id"] = dmm_ids.get(str(r18_id))
        group["r18_ids"].append(str(r18_id))
        for key in keys:
            owners[key] = group
    new_rows = []
    reused = 0
    for group in groups:
        if group["existing"]:
            reused += 1
        primary = (group["name_kanji"] or group["name_kana"]
                   or group["name_romaji"] or group["names"][0])
        names = [primary, *[name for name in group["names"] if name != primary]]
        new_rows.append({
            "r18_id": group["r18_ids"][0],
            "r18_ids": group["r18_ids"],
            "person_id": None,
            "new": True,
            "region": "japan",
            "names": names,
            "image": group["image"],
            "name_kanji": group["name_kanji"],
            "name_kana": group["name_kana"],
            "name_romaji": group["name_romaji"],
            "dmm_id": group["dmm_id"],
        })
    print(f"R18 新人档案 {len(new_rows):,} 位（新建 {len(new_rows) - reused:,} / "
          f"复用上轮 {reused:,}；库内重名跳过 {skipped_collision:,} / "
          f"无有效名跳过 {skipped_empty:,}）", flush=True)
    return new_rows


def export(hits: dict[int, dict], new_rows: list[dict], per_actress: int,
           dmm_ids: dict[str, str]) -> None:
    connection = sqlite3.connect(CACHE_DB)
    connection.row_factory = sqlite3.Row
    print(f"DMM 演员 ID 映射命中 {len(dmm_ids):,} 位 R18 女优", flush=True)
    # 1) 女优补丁：R18 ID + 头像 + 假名/罗马字别名 + DMM 演员 ID
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
                "names": [clean(name) for name in names if clean(name)],
                "image": full_image(row["image_url"]),
                "name_kanji": clean(row["name_kanji"]),
                "name_kana": clean(row["name_kana"]),
                "name_romaji": clean(row["name_romaji"]),
                "dmm_id": dmm_ids.get(str(row["id"])),
            })
    actress_rows.extend(new_rows)
    with open(OUT_ACTRESSES, "w", encoding="utf-8") as handle:
        json.dump(actress_rows, handle, ensure_ascii=False)
    print(f"写出 {OUT_ACTRESSES}：{len(actress_rows)} 位（新建档 {len(new_rows):,}）",
          flush=True)

    # 2) 作品：按人物截取最近 N 部（同一部多人参演只导出一次）。
    #    不做合集过滤：合集本身也是真实商品，genres 里带「ベスト・総集編」，界面可自行筛选。
    #    已在库内的女优导出全字段；新建档女优的作品只留番号 / 标题 / 日期 / 封面。
    target_names: dict[str, str] = {}
    caps: dict[str, int] = {}
    for rid in matched_ids:
        target_names[rid] = hits[rid]["names"][0]
        caps[rid] = per_actress
    for group in new_rows:
        for raw in group["r18_ids"]:
            # 缓存库的 id 列是 TEXT，这里统一用字符串键，和 SQL 返回的类型一致。
            target_names[str(raw)] = group["names"][0]
            caps[str(raw)] = per_actress
    remaining = sum(caps.values())
    picked: dict[str, None] = {}
    picked_dvd: set[str] = set()
    connection.execute(
        "CREATE TEMP TABLE target_actresses (id INTEGER PRIMARY KEY, cap INTEGER)")
    connection.executemany("INSERT OR REPLACE INTO target_actresses VALUES (?, ?)",
                           ((rid, cap) for rid, cap in caps.items()))
    cursor = connection.execute(
        """SELECT va.content_id, va.actress_id, v.dvd_id
           FROM derived_video_actress va
           JOIN target_actresses t ON t.id = va.actress_id
           JOIN derived_video v ON v.content_id = va.content_id
           WHERE v.jacket_full_url IS NOT NULL AND v.release_date IS NOT NULL
           ORDER BY v.release_date DESC, v.dvd_id, v.content_id""")
    for content_id, actress_id, dvd_id in cursor:
        dvd_key = (dvd_id or "").casefold()
        # 同一番号只留最新一条（普通版 / BOD / 特典共用 dvd_id），
        # 先在选片阶段排掉，免得重复条目吃掉女优的 100 部配额。
        if (not dvd_key or content_id in picked or dvd_key in picked_dvd
                or caps.get(actress_id, 0) <= 0):
            continue
        caps[actress_id] -= 1
        remaining -= 1
        picked[content_id] = None
        picked_dvd.add(dvd_key)
        if remaining <= 0:
            break
    print(f"选中作品 {len(picked):,} 部", flush=True)

    content_ids = list(picked)
    # 选中的 40 万 content_id 灌进临时表：参演者 / 分类 / 导演都用一次 join 取完，
    # 比「900 个一批」反复查 960 万行的分类表快一个量级。
    connection.execute("CREATE TEMP TABLE picked_ids (content_id TEXT PRIMARY KEY)")
    connection.executemany("INSERT OR IGNORE INTO picked_ids VALUES (?)",
                           ((item,) for item in content_ids))

    # 参演名单单独按 content_id 取，避免截断时漏掉同一部里靠后的共演者；
    # 按 ordinality 排序，导出顺序就是 R18 的出演顺位（1 = 首位）。
    # 同时记下「有库内女优」的作品：这些导出全字段，只有新女优的作品走精简。
    actress_map: dict[str, list[str]] = {}
    full_contents: set[str] = set()
    for row in connection.execute(
            "SELECT va.content_id, va.actress_id "
            "FROM derived_video_actress va "
            "JOIN picked_ids p ON p.content_id = va.content_id "
            "ORDER BY va.content_id, CAST(va.ordinality AS INTEGER), va.actress_id"):
        name = target_names.get(row["actress_id"])
        if not name:
            continue
        if row["actress_id"] in hits:
            full_contents.add(row["content_id"])
        names = actress_map.setdefault(row["content_id"], [])
        if name not in names:
            names.append(name)

    makers = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_maker")}
    labels = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_label")}
    series = {str(row["id"]): (row["name_ja"] or row["name_en"] or "")
              for row in connection.execute("SELECT * FROM derived_series")}

    genres: dict[str, list[str]] = {}
    for row in connection.execute(
            "SELECT vc.content_id, c.name_ja, c.name_en "
            "FROM derived_video_category vc "
            "JOIN picked_ids p ON p.content_id = vc.content_id "
            "JOIN derived_category c ON c.id = vc.category_id"):
        name = row["name_ja"] or row["name_en"]
        if not name:
            continue
        bucket = genres.setdefault(row["content_id"], [])
        if name not in bucket:
            bucket.append(name)

    video_directors: dict[str, str] = {}
    for row in connection.execute(
            "SELECT vd.content_id, d.name_kanji, d.name_romaji "
            "FROM derived_video_director vd "
            "JOIN picked_ids p ON p.content_id = vd.content_id "
            "JOIN derived_director d ON d.id = vd.director_id"):
        name = clean(row["name_kanji"]) or clean(row["name_romaji"])
        if name and row["content_id"] not in video_directors:
            video_directors[row["content_id"]] = name

    videos = []
    seen_content: set[str] = set()
    for start in range(0, len(content_ids), 900):
        chunk = content_ids[start:start + 900]
        for row in connection.execute(
                f"SELECT * FROM derived_video WHERE content_id IN "
                f"({','.join('?' * len(chunk))}) ORDER BY content_id, dvd_id",
                chunk):
            dvd_id = clean(row["dvd_id"]) or ""
            if not dvd_id or row["content_id"] in seen_content:
                # dump 里同一 content_id 会有多行（ANPD-01 / ANPD001 这类番号写法），
                # 只留第一行，否则会导出重复作品。
                continue
            seen_content.add(row["content_id"])
            # 新建档女优的作品走精简：只要番号 / 标题 / 日期 / 封面，
            # 不导剧照、简介、分类、导演、试看，避免为长尾作品拉大库体。
            minimal = row["content_id"] not in full_contents
            videos.append({
                "content_id": row["content_id"],
                "dvd_id": dvd_id,
                "title_ja": clean(row["title_ja"]),
                "title_en": clean(row["title_en"]),
                # comment_ja 大多为空，英文简介覆盖面更广，二选一。
                "comment": None if minimal else (
                    clean(row["comment_ja"]) or clean(row["comment_en"])),
                "release_date": row["release_date"],
                "runtime": row["runtime_mins"],
                "director": None if minimal else video_directors.get(row["content_id"]),
                "maker": clean(makers.get(str(row["maker_id"]))),
                "label": clean(labels.get(str(row["label_id"]))),
                "series": clean(series.get(str(row["series_id"]))),
                "genres": [] if minimal else [
                    clean(item) for item in genres.get(row["content_id"], []) if clean(item)],
                "cover": full_jacket(row["jacket_full_url"]),
                # 列表页用缩略图（ps 版），比封面小一个数量级。
                "thumb": full_jacket(row["jacket_thumb_url"]),
                # dump 只存首尾两张剧照文件名，中间序号不保证连续，不做推测拼 URL。
                "samples": [] if minimal else [url for url in (
                    full_jacket(row["gallery_thumb_first"]),
                    full_jacket(row["gallery_thumb_last"]),
                ) if url],
                "trailer": None if minimal else row["sample_url"],
                "actresses": actress_map.get(row["content_id"], []),
            })
    connection.close()
    videos.sort(key=lambda item: item["release_date"] or "", reverse=True)
    # 同一 dvd_id 可能有多个 content_id（普通版 / BOD 版 / 特典版），只保留最新那条；
    # 带 BOD 后缀且普通版也在库里时，直接算重复。
    all_ids = {item["dvd_id"].casefold() for item in videos}
    unique = []
    seen_dvd = set()
    for item in videos:
        key = item["dvd_id"].casefold()
        if key.endswith("bod") and key[:-3] in all_ids:
            continue
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
    parser.add_argument("--per-actress", type=int, default=100,
                        help="每位女优最多导出最近多少部作品（0 = 全部）")
    parser.add_argument("--stats", action="store_true", help="只打印规模与匹配率")
    parser.add_argument("--refresh", action="store_true",
                        help="强制重新解析 dump（默认复用 raw/r18/r18.sqlite 缓存）")
    parser.add_argument("--existing-only", action="store_true",
                        help="只补已有女优，不给未匹配的 R18 女优建档（旧行为）")
    args = parser.parse_args()
    if args.refresh and os.path.exists(CACHE_DB):
        os.remove(CACHE_DB)
    if not os.path.exists(CACHE_DB):
        if not os.path.exists(args.dump):
            raise SystemExit(f"没有 dump 也没有缓存：{args.dump}")
        parse_dump(args.dump)
    mapping, r18_only = load_catalog_names()
    print(f"库内名字键 {len(mapping):,} 个（仅 R18 建档 {len(r18_only):,} 人）", flush=True)
    hits = match_actresses(mapping, r18_only)
    connection = sqlite3.connect(CACHE_DB)
    dmm_ids = dmm_histrion_ids(connection)
    new_rows = []
    if not args.existing_only:
        new_rows = collect_new_actresses(connection, mapping, r18_only, hits, dmm_ids)
    connection.close()
    stats(hits, dmm_ids)
    if not args.stats:
        export(hits, new_rows, args.per_actress, dmm_ids)


if __name__ == "__main__":
    main()
