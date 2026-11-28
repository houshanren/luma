#!/usr/bin/env python3
"""库内姓名反查：把 SEO 标题抓到的记录绑定到库内已有人物，只补已有条目不新增。

用法：python3 Tools/catalog_build/build/match_cn_profiles.py cn_profiles_web7.json [more.json ...]
在 raw/ 下就地重写输入文件，原文件备份成 *.unmatched.json。

匹配规则：
- 取记录的 name + raw_title + summary + 作品标题拼成探针文本；
- 在库内所有主名/别名里找「出现在探针文本中的最长名字」；
- 命中：记录改名为库内主名（原名列进 aliases），走正常合并；
- 未命中：丢弃（避免 SEO 标题把陌生人名灌进库）。
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
DB = os.environ.get("LUMA_CATALOG_DB") or os.path.expanduser("~/Downloads/catalog.sqlite")
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

GENERIC_WORDS = {
    "模特", "写真", "图集", "福利姬", "coser", "Coser", "COSER", "合集", "作品",
    "小姐", "女神", "美女", "老师", "少女", "模特儿", "网红", "主播",
}
MIN_CJK = 3
MIN_LATIN = 4


def normalize(value):
    text = unicodedata.normalize("NFKC", (value or "")).casefold()
    return re.sub(r"[\s\-_·・.。,，'\"()（）【】\[\]]+", "", text)


def load_library_names():
    connection = sqlite3.connect(DB)
    rows = connection.execute("SELECT name, aliases FROM actresses").fetchall()
    connection.close()
    # name → 库内主名
    mapping = {}
    for name, aliases_json in rows:
        names = [name]
        try:
            for alias in json.loads(aliases_json or "[]"):
                if alias and alias not in names:
                    names.append(alias)
        except ValueError:
            pass
        for candidate in names:
            key = normalize(candidate)
            if key and key not in mapping:
                mapping[key] = name
    return mapping


def matchable(name):
    if name in GENERIC_WORDS:
        return False
    has_cjk = bool(re.search(r"[\u4e00-\u9fa5]", name))
    if has_cjk:
        return len(re.sub(r"[^\u4e00-\u9fa5]", "", name)) >= MIN_CJK
    return len(re.sub(r"[^A-Za-z0-9]", "", name)) >= MIN_LATIN


def main():
    if len(__import__("sys").argv) < 2:
        raise SystemExit(__doc__)
    mapping = load_library_names()
    # 排序：名字长的优先（最长子串优先）
    candidates = sorted(
        ((key, canonical) for key, canonical in mapping.items() if matchable(canonical)),
        key=lambda item: -len(item[0]))
    print(f"库内候选名 {len(candidates)} 个")

    for filename in __import__("sys").argv[1:]:
        path = os.path.join(RAW, filename) if not os.path.isabs(filename) else filename
        if not os.path.exists(path):
            print(f"跳过（不存在）：{filename}")
            continue
        records = json.load(open(path, encoding="utf-8"))
        kept = []
        renamed = 0
        for record in records:
            name = (record.get("name") or "").strip()
            probe_parts = [name, record.get("raw_title") or "",
                           (record.get("summary") or "")[:200]]
            for work in (record.get("works") or [])[:3]:
                probe_parts.append(work.get("title") or "")
            probe = normalize(" ".join(probe_parts))
            hit = None
            for key, canonical in candidates:
                if key in probe:
                    hit = canonical
                    break
            if hit is None:
                continue
            if name and name != hit and name not in (record.get("aliases") or []):
                record.setdefault("aliases", [])
                record["aliases"].append(name)
            record["name"] = hit
            renamed += 1
            kept.append(record)
        shutil.copy(path, path + ".unmatched.json")
        json.dump(kept, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"{filename}: {len(records)} → {len(kept)}（匹配率 {len(kept) * 100 // max(1, len(records))}%，"
              f"改名 {renamed}）")


if __name__ == "__main__":
    main()
