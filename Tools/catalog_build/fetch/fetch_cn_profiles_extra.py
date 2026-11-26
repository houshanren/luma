#!/usr/bin/env python3
"""第四轮：从影语阁 / 乐妖图 / 图罗记 / 喵风向 / 元气领域 / 虾仁猪心补国内人物档案。

用法：python3 Tools/catalog_build/fetch/fetch_cn_profiles_extra.py
输出：Tools/catalog_build/raw/cn_profiles_web5.json

六站均为 WordPress，走 REST 一次取 100 篇正文。
只保留能解析出「生日 / 身高 / 三围」其中至少一项的条目，避免把纯作品页当人物。
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_cn_profiles as base  # noqa: E402
import fetch_cn_profiles_more as more  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "cn_profiles_web5.json")

SITES = (
    ("https://www.yingyuge.com", "yingyuge"),
    ("https://www.leyaotu.com", "leyaotu"),
    ("https://www.tuluoj.cc", "tuluoj"),
    ("https://www.miaofengxiang.com", "miaofengxiang"),
    ("https://yuanqi6.com", "yuanqi6"),
    ("https://www.xiarenzhuxin.com", "xiarenzhuxin"),
)
HINT = re.compile(r"(个人资料|生日|出生|身高|三围|Coser|coser|福利姬|模特)")


def fetch_site(base_url, source, records):
    page = 1
    while True:
        url = (f"{base_url}/wp-json/wp/v2/posts?per_page=100&page={page}"
               f"&_fields=id,title,link,content")
        data = base.fetch_json(url)
        if not data:
            break
        before_all = len(records)
        for post in data:
            title = html.unescape(re.sub(r"<[^>]+>", "", (post.get("title") or {}).get("rendered", "")))
            content = (post.get("content") or {}).get("rendered", "")
            lines = base.clean_lines(base.clean_text(content))
            joined = "\n".join(lines)
            if not HINT.search(joined):
                continue
            name = more.person_name(title, lines) or base.clean_title_name(title)
            if not name:
                continue
            name = re.sub(r"(个人|资料|简介|介绍)$", "", name).strip()
            before = len(records)
            base.add_record(records, raw_name=name, source=source,
                            source_url=post.get("link") or "", lines=lines,
                            raw_html=content, title_hint=title)
            if len(records) > before:
                record = records[-1]
                if not (record.get("birth_date") or record.get("height") or record.get("bust")):
                    records.pop()
        print(f"  {source} 第 {page} 页，新增 {len(records) - before_all}，累计 {len(records)}")
        if len(data) < 100:
            break
        page += 1
        time.sleep(1.0)


def main():
    os.makedirs(RAW, exist_ok=True)
    records: list[dict] = []
    for base_url, source in SITES:
        try:
            fetch_site(base_url, source, records)
        except Exception as error:  # 单站失败不影响其它站
            print(f"  {source} 中断：{type(error).__name__}")
    for record in records:
        record["birthplace"] = base.normalize_place(record.get("birthplace"))
    json.dump(records, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"完成：{len(records)} 条，生日 {sum(1 for r in records if r.get('birth_date'))}，"
          f"身高 {sum(1 for r in records if r.get('height'))} → {OUT}")


if __name__ == "__main__":
    main()
