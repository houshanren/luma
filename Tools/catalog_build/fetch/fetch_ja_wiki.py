#!/usr/bin/env python3
"""抓取日文维基「日本のAV女優」分类的信息框，补人物档案。

用法：python3 Tools/catalog_build/fetch/fetch_ja_wiki.py
输出：Tools/catalog_build/raw/ja_wiki_people.json

只抓公开页面，限速 + 429 退避；不下载图片。
使用 generator=categorymembers + prop=revisions，一次取 100 页正文，减少请求数。
"""

from __future__ import annotations

import html
import json
import os
import re
import time

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "ja_wiki_people.json")
API = "https://ja.wikipedia.org/w/api.php"
CATEGORY = "Category:日本のAV女優"
PROXIES = {"http": "http://127.0.0.1:8118", "https": "http://127.0.0.1:8118"}
BATCH = 100

SESSION = requests.Session()
SESSION.proxies.update(PROXIES)
SESSION.headers.update({
    "User-Agent": "LumaCatalog/1.0 (local metadata build; contact: none)",
    "Accept": "application/json",
})


def get_json(params, tries=8):
    for attempt in range(tries):
        try:
            response = SESSION.get(API, params=params, timeout=60)
            if response.status_code == 429:
                wait = int(response.headers.get("Retry-After") or 15)
                print(f"    429，等待 {wait}s")
                time.sleep(wait)
                continue
            if response.status_code >= 500:
                time.sleep(5 * (attempt + 1))
                continue
            response.raise_for_status()
            return response.json()
        except (requests.RequestException, ValueError) as error:
            print(f"    请求失败：{type(error).__name__}，重试 {attempt + 1}/{tries}")
            time.sleep(5 * (attempt + 1))
    return None


def strip_disambiguation(title):
    return re.sub(r"\s*[（(](?:AV女優|女優|アダルト女優|人物)[）)]\s*$", "", title).strip()


def clean_wiki(value):
    if not value:
        return ""
    text = str(value)
    text = re.sub(r"<ref[^>]*/>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    for _ in range(3):
        text = re.sub(r"\{\{[^{}]*\}\}", "", text)
    text = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]+)\]\]", r"\1", text)
    text = re.sub(r"\[https?://\S+\s*([^\]]*)\]", r"\1", text)
    text = re.sub(r"<br\s*/?>", "、", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("'''", "").replace("''", "")
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text)
    return text.strip(" 、,，")


def parse_birth(raw):
    text = str(raw or "")
    match = re.search(r"\{\{\s*生年月日と年齢\s*\|\s*(\d{4})\s*\|\s*(\d{1,2})\s*\|\s*(\d{1,2})", text)
    if match:
        year, month, day = (int(part) for part in match.groups())
        return f"{year:04d}-{month:02d}-{day:02d}", "day"
    match = re.search(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日", text)
    if match:
        year, month, day = (int(part) for part in match.groups())
        return f"{year:04d}-{month:02d}-{day:02d}", "day"
    match = re.search(r"(\d{4})[-/](\d{1,2})[-/](\d{1,2})", text)
    if match:
        year, month, day = (int(part) for part in match.groups())
        return f"{year:04d}-{month:02d}-{day:02d}", "day"
    match = re.search(r"(19\d{2}|20\d{2})", text)
    if match:
        return match.group(1), "year"
    return None, None


def infobox_params(text):
    params = {}
    for line in text.splitlines():
        match = re.match(r"\s*\|\s*([^=]+?)\s*=\s*(.*)$", line)
        if match:
            params[match.group(1).strip()] = match.group(2).strip()
    return params


def first_url(raw, require_words=()):
    for match in re.finditer(r"\[(https?://[^\s\]]+)\s*([^\]]*)\]", raw or ""):
        url, label = match.group(1), match.group(2)
        if "web.archive.org" in url:
            continue
        if "wayback" in raw[max(0, match.start() - 100):match.start()].lower():
            continue
        if require_words and not any(word in (label + url).lower() for word in require_words):
            continue
        return url
    for match in re.finditer(r"https?://[^\s\]\|}<]+", raw or ""):
        url = match.group(0)
        if "web.archive.org" in url:
            continue
        if "wayback" in raw[max(0, match.start() - 100):match.start()].lower():
            continue
        return url
    return None


def parse_page(title, text):
    params = infobox_params(text)
    plain = clean_wiki(text)
    lead = plain[:1600]

    raw_birth = params.get("生年月日") or ""
    if not raw_birth:
        match = re.search(r"生年月日[：:]\s*([^\n]{4,40})", plain)
        raw_birth = match.group(1) if match else ""
    birth_date, birth_precision = parse_birth(raw_birth)
    if not birth_date:
        match = re.search(r"((?:19|20)\d{2})年\s*(\d{1,2})月\s*(\d{1,2})日", plain[:3000])
        if match:
            year, month, day = (int(part) for part in match.groups())
            birth_date, birth_precision = f"{year:04d}-{month:02d}-{day:02d}", "day"
    if not birth_date:
        match = re.search(r"(19\d{2}|20\d{2})", clean_wiki(params.get("生年")))
        if match:
            birth_date, birth_precision = match.group(1), "year"

    height = None
    match = re.search(r"(\d{2,3})", clean_wiki(params.get("身長")))
    if match:
        value = int(match.group(1))
        if 130 <= value <= 200:
            height = value

    bust = waist = hips = None
    measure = clean_wiki(params.get("スリーサイズ"))
    match = re.search(r"B\s*(\d{2,3}).*?W\s*(\d{2,3}).*?H\s*(\d{2,3})",
                      measure, re.IGNORECASE)
    if not match:
        match = re.search(r"(\d{2,3})\s*[-/]\s*(\d{2,3})\s*[-/]\s*(\d{2,3})", measure)
    if match:
        bust, waist, hips = (int(part) for part in match.groups())
        if not all(40 <= value <= 160 for value in (bust, waist, hips)):
            bust = waist = hips = None
    for key, field in (("バスト", "bust"), ("ウエスト", "waist"), ("ヒップ", "hips")):
        if locals()[field] is not None:
            continue
        match = re.search(r"(\d{2,3})", clean_wiki(params.get(key)))
        if match:
            value = int(match.group(1))
            if 40 <= value <= 160:
                if field == "bust":
                    bust = value
                elif field == "waist":
                    waist = value
                else:
                    hips = value

    cup = None
    cup_text = clean_wiki(params.get("カップ")) or clean_wiki(params.get("ブラサイズ"))
    match = re.search(r"([A-K])\s*(?:カップ|\d|$)", cup_text, re.IGNORECASE)
    if match:
        cup = match.group(1).upper()

    blood_type = None
    match = re.search(r"(AB|A|B|O)\s*型", clean_wiki(params.get("血液型")), re.IGNORECASE)
    if match:
        blood_type = match.group(1).upper()

    debut_year = None
    match = re.search(r"(19\d{2}|20\d{2})", clean_wiki(params.get("デビュー")))
    if not match:
        match = re.search(r"((?:19|20)\d{2})年[^。]{0,40}?デビュー", plain)
    if match:
        debut_year = int(match.group(1))

    birthplace = clean_wiki(params.get("出身地"))
    if birthplace:
        birthplace = re.sub(r"^(日本|JPN)\s*[・,，]?\s*", "", birthplace)
        birthplace = birthplace.lstrip("・,， ")
        birthplace = birthplace[:60]
    else:
        match = re.search(r"出身[地は：:]\s*([^。\n]{2,40}?)(?:出身|。)", plain)
        birthplace = clean_wiki(match.group(1))[:60] if match else None

    agency = clean_wiki(params.get("所属事務所"))
    if not agency:
        match = re.search(r"所属事務所[は：:]\s*([^。\n]{2,60})", plain)
        if not match:
            match = re.search(r"事務所[は：:]\s*([^。\n]{2,50})", plain)
        if not match:
            match = re.search(r"([^。、\n]{2,30}?)所属(?:。|、|$)", plain)
        agency = clean_wiki(match.group(1)) if match else None
    if agency:
        agency = re.sub(r"^(所属事務所|事務所)[は：:]?", "", agency).strip()[:80] or None

    official_site = first_url(params.get("公式サイト"))
    if not official_site:
        official_site = first_url(text, require_words=("公式", "オフィシャル", "official"))
    match = re.search(r"\{\{\s*(?:Official website|Official|公式サイト)\s*\|\s*(https?://[^\s\}|]+)", text,
                      re.IGNORECASE)
    if not official_site and match:
        official_site = match.group(1)

    hobby_parts = [clean_wiki(params.get("趣味")), clean_wiki(params.get("特技"))]
    if not any(hobby_parts):
        match = re.search(r"趣味[は：:]\s*([^。=\n]{2,100})", plain)
        if match:
            hobby_parts.append(clean_wiki(match.group(1)))
        match = re.search(r"特技[は：:]\s*([^。=\n]{2,100})", plain)
        if match:
            hobby_parts.append(clean_wiki(match.group(1)))
    hobby = "、".join(part for part in hobby_parts if part)[:120] or None

    aliases = []
    for part in re.split(r"[、,，/／]", clean_wiki(params.get("別名"))):
        part = part.strip()
        if 2 <= len(part) <= 30 and part not in aliases:
            aliases.append(part)

    status = None
    if re.search(r"(AV女優|女優)を引退|引退した|引退している", lead):
        status = "retired"
    elif "活動休止" in lead:
        status = "hiatus"

    name = strip_disambiguation(title)
    if not (birth_date or height or bust or agency or official_site):
        return None

    ruby = clean_wiki(params.get("読み")) or clean_wiki(params.get("よみがな"))
    if not ruby:
        match = re.search(r"'''[^']+'''\s*[（(]\s*([ぁ-んァ-ヶー\s]{2,30})", text)
        if match:
            ruby = clean_wiki(match.group(1))
            ruby = re.split(r"[、,，/／]", ruby)[0].strip()

    return {
        "name": name,
        "title": title,
        "url": "https://ja.wikipedia.org/wiki/" + requests.utils.quote(title.replace(" ", "_")),
        "aliases": aliases,
        "ruby": ruby or None,
        "birth_date": birth_date,
        "birth_precision": birth_precision,
        "height": height,
        "bust": bust,
        "waist": waist,
        "hips": hips,
        "cup": cup,
        "blood_type": blood_type,
        "birthplace": birthplace or None,
        "debut_year": debut_year,
        "agency": agency,
        "official_site": official_site,
        "hobby": hobby,
        "status": status,
    }


def main():
    os.makedirs(RAW, exist_ok=True)
    people = {}
    continue_params = {}
    page_count = 0

    while True:
        params = {
            "action": "query",
            "generator": "categorymembers",
            "gcmtitle": CATEGORY,
            "gcmtype": "page",
            "gcmlimit": str(BATCH),
            "prop": "revisions",
            "rvprop": "content",
            "rvslots": "main",
            "format": "json",
            "formatversion": "2",
            "maxlag": "5",
        }
        params.update(continue_params)
        data = get_json(params)
        if not data:
            print("抓取失败，保留已有结果")
            break
        pages = data.get("query", {}).get("pages", [])
        for page in pages:
            title = page.get("title")
            if not title or page.get("missing"):
                continue
            revisions = page.get("revisions") or []
            if not revisions:
                continue
            content = revisions[0].get("slots", {}).get("main", {}).get("content", "")
            parsed = parse_page(title, content)
            if parsed:
                people[title] = parsed
        page_count += len(pages)
        json.dump(people, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"  {page_count} 页，资料 {len(people)} 人")
        cont = data.get("continue")
        if not cont:
            break
        continue_params = cont
        time.sleep(1.2)

    print(f"完成：{len(people)} 人 → {OUT}")


if __name__ == "__main__":
    main()
