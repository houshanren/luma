#!/usr/bin/env python3
"""第六轮（续2）：cos2cy 编号人物页（001–340）。

用法：python3 Tools/catalog_build/fetch_cn_profiles_round8.py
输出：Tools/catalog_build/raw/cn_profiles_web8.json

页面形态：
- 人物页  https://www.cos2cy.com/NNN.html  标题『001-过期米线线喵[更新至 182 期]』
  正文含 常用名/国籍/出生日期/活跃领域/主要平台/个人经历 的完整传记。
- 图集页  标题『某某cosplay写真作品-No.XXX』——跳过。

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

# 本轮本机代理端口为 7890（8118 已停）
base.PROXIES = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
base.SESSION.proxies.update(base.PROXIES)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "cn_profiles_web8.json")

MAX_NUM = 340
PROFILE_TITLE = re.compile(r"^\d{3}\s*[-–—]\s*(.{1,30}?)\s*(?:\[[^\]]*\])?\s*$")


def fetch_page(n):
    url = f"https://www.cos2cy.com/{n:03d}.html"
    for attempt in range(3):
        try:
            r = base.SESSION.get(url, timeout=25)
            if r.status_code == 200:
                return r.text
            if r.status_code == 404:
                return None
        except Exception:
            pass
        time.sleep(2 * (attempt + 1))
    return None


def main():
    os.makedirs(RAW, exist_ok=True)
    records: list[dict] = []
    for n in range(1, MAX_NUM + 1):
        text = fetch_page(n)
        if not text:
            continue
        m = re.search(r"<title>(.*?)</title>", text, re.S)
        title = html.unescape((m.group(1) if m else "")).strip()
        pm = PROFILE_TITLE.match(title.split("-COS")[0].strip())
        # 图集页标题形如『过期米线线喵cosplay写真作品-No.020-…』，直接跳过
        if re.search(r"(写真作品|No\.\d+)", title[:60]):
            continue
        name = pm.group(1).strip() if pm else base.clean_title_name(title)
        name = re.sub(r"\s*更新至.*$", "", name).strip()
        if not name or not base.looks_like_person(name):
            continue
        content = text
        lines = base.clean_lines(base.clean_text(content))
        before = len(records)
        base.add_record(records, raw_name=name, source="cos2cy",
                        source_url=f"https://www.cos2cy.com/{n:03d}.html",
                        lines=lines, raw_html=content, title_hint=title)
        if len(records) > before:
            record = records[-1]
            # 人物传记页即使缺生日/身高也保留（有完整简介）
            if not (record.get("birth_date") or record.get("height") or record.get("bust")
                    or record.get("summary")):
                records.pop()
        if n % 40 == 0:
            print(f"  已到 {n:03d}，累计 {len(records)} 条", flush=True)
        time.sleep(0.4)
    for record in records:
        record["birthplace"] = base.normalize_place(record.get("birthplace"))
    json.dump(records, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"完成：{len(records)} 条，生日 {sum(1 for r in records if r.get('birth_date'))}，"
          f"身高 {sum(1 for r in records if r.get('height'))} → {OUT}")


if __name__ == "__main__":
    main()
