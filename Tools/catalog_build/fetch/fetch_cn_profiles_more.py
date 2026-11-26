#!/usr/bin/env python3
"""第二轮：从泡面站 / 梗语百科补华语 Coser、写真模特、福利姬档案。

用法：python3 Tools/catalog_build/fetch/fetch_cn_profiles_more.py
输出：Tools/catalog_build/raw/cn_profiles_web2.json

两站都是 WordPress，直接走 REST 一次取 100 篇正文，比逐页抓 HTML 省请求。
只保留能解析出「生日 / 身高 / 出生地 / 简介」的条目；解析不出名字的整条丢弃。
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

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "cn_profiles_web2.json")

NAME_SUFFIX = re.compile(
    r"(个人资料介绍及图片|个人资料介绍|个人资料|资料介绍及图片|介绍及图片|是谁|简介|"
    r"资料|图片|写真作品|COSPLAY).*$")
PERSON_HINT = re.compile(r"(个人资料|生日|出生|身高|三围|Coser|coser|福利姬|模特)")


def person_name(title, lines):
    text = html.unescape(re.sub(r"<[^>]+>", "", title or "")).strip()
    for line in lines[:40]:
        match = re.match(r"^([\u4e00-\u9fa5A-Za-z0-9_·．.\-]{2,22})[，,]\s*(?:19|20)\d{2}\s*年", line)
        if match:
            return match.group(1).strip()
        match = re.match(r"^(?:名字|姓名|中文名|本名|网名|艺名|昵称)[：:]\s*([^\s，。]{2,20})$", line)
        if match:
            return match.group(1).strip()
    name = NAME_SUFFIX.sub("", text).strip()
    return name if 2 <= len(name) <= 22 else None


def fetch_site(base_url, records):
    page = 1
    while True:
        url = (f"{base_url}/wp-json/wp/v2/posts?per_page=100&page={page}"
               f"&_fields=id,title,link,content")
        data = base.fetch_json(url)
        if not data:
            break
        kept = 0
        for post in data:
            title = html.unescape(re.sub(r"<[^>]+>", "", (post.get("title") or {}).get("rendered", "")))
            content = (post.get("content") or {}).get("rendered", "")
            lines = base.clean_lines(base.clean_text(content))
            joined = "\n".join(lines)
            if not PERSON_HINT.search(joined):
                continue
            name = person_name(title, lines)
            if not name:
                continue
            before = len(records)
            base.add_record(records, raw_name=name, source=base_url.split("//")[-1].replace("www.", ""),
                            source_url=post.get("link") or "", lines=lines,
                            raw_html=content, title_hint=title)
            kept += len(records) - before
        print(f"  {base_url} 第 {page} 页，新增 {kept}，累计 {len(records)}")
        if len(data) < 100:
            break
        page += 1
        time.sleep(1.0)


def main():
    os.makedirs(RAW, exist_ok=True)
    records: list[dict] = []
    fetch_site("https://www.paomianz.com", records)
    fetch_site("https://wiki.yglsr.com", records)
    json.dump(records, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    with_facts = sum(1 for record in records if record.get("birth_date") or record.get("height"))
    print(f"完成：{len(records)} 条，其中有生日/身高 {with_facts} 条 → {OUT}")


if __name__ == "__main__":
    main()
