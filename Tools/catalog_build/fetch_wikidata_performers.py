#!/usr/bin/env python3
"""P0 新源：Wikidata 女性成人演员档案（生日 / 身高 / 社交 / 官网）。

用法：python3 Tools/catalog_build/fetch_wikidata_performers.py
输出：Tools/catalog_build/raw/wikidata_performers.json

口径：
- 职业 = 色情演员（Q488111），性别 = 女（Q6581072），且是人类。
- 只保留能映射到 japan / korea / taiwan / hongkong / china / western 的人；
  国家缺失的行跳过，避免把地区猜错。
- WDQS 目前限流 1 请求/分钟，脚本按 2,500 人一段、段间 sleep 65s 抓取；
  命中 429 会再等 70s 重试。
- 输出只含文字字段与社交 URL；不下载图片。
"""

from __future__ import annotations

import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "wikidata_performers.json")
ENDPOINT = "https://query.wikidata.org/sparql"
CHUNK = 2500
MAX_CHUNKS = 12

COUNTRY_REGION = {
    "japan": "japan", "日本": "japan",
    "south korea": "korea", "republic of korea": "korea", "korea": "korea",
    "taiwan": "taiwan", "republic of china": "taiwan",
    "hong kong": "hongkong", "british hong kong": "hongkong",
    "china": "china", "people's republic of china": "china",
    "united states of america": "western", "united states": "western",
    "united kingdom": "western", "england": "western", "scotland": "western",
    "canada": "western", "australia": "western", "new zealand": "western",
    "france": "western", "germany": "western", "italy": "western",
    "spain": "western", "portugal": "western", "netherlands": "western",
    "belgium": "western", "sweden": "western", "norway": "western",
    "denmark": "western", "finland": "western", "iceland": "western",
    "switzerland": "western", "austria": "western", "ireland": "western",
    "poland": "western", "czech republic": "western", "czechia": "western",
    "slovakia": "western", "hungary": "western", "romania": "western",
    "bulgaria": "western", "greece": "western", "croatia": "western",
    "serbia": "western", "ukraine": "western", "russia": "western",
    "brazil": "western", "mexico": "western", "argentina": "western",
    "colombia": "western", "venezuela": "western", "chile": "western",
    "peru": "western", "cuba": "western", "dominican republic": "western",
    "south africa": "western", "israel": "western", "turkey": "western",
}

QUERY = """SELECT ?p ?en ?ja ?zh ?ko ?birth ?height ?countryLabel ?ig ?tw ?yt ?site ?imdb WHERE {
  ?p wdt:P106 wd:Q488111 ; wdt:P21 wd:Q6581072 ; wdt:P31 wd:Q5 .
  OPTIONAL { ?p rdfs:label ?en FILTER(lang(?en) = "en") }
  OPTIONAL { ?p rdfs:label ?ja FILTER(lang(?ja) = "ja") }
  OPTIONAL { ?p rdfs:label ?zh FILTER(lang(?zh) = "zh") }
  OPTIONAL { ?p rdfs:label ?ko FILTER(lang(?ko) = "ko") }
  OPTIONAL { ?p wdt:P569 ?birth }
  OPTIONAL { ?p wdt:P2048 ?height }
  OPTIONAL { ?p wdt:P27 ?country }
  OPTIONAL { ?p wdt:P2003 ?ig }
  OPTIONAL { ?p wdt:P2002 ?tw }
  OPTIONAL { ?p wdt:P2397 ?yt }
  OPTIONAL { ?p wdt:P856 ?site }
  OPTIONAL { ?p wdt:P345 ?imdb }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en,ja,zh,ko". }
}
ORDER BY ?p
LIMIT %d OFFSET %d"""


def query_page(offset):
    url = ENDPOINT + "?" + urllib.parse.urlencode({
        "query": QUERY % (CHUNK, offset), "format": "json"})
    request = urllib.request.Request(url, headers={
        "User-Agent": "Luma-catalog/1.0 (local research; contact: dev@localhost)",
        "Accept": "application/sparql-results+json",
    })
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)["results"]["bindings"]
        except urllib.error.HTTPError as error:
            if error.code == 429:
                print(f"  429 限流，等 70s（第 {attempt + 1} 次）", flush=True)
                time.sleep(70)
                continue
            print(f"  HTTP {error.code}，跳过该段", flush=True)
            return []
        except (urllib.error.URLError, ValueError) as error:
            print(f"  请求失败：{error}", flush=True)
            time.sleep(10 * (attempt + 1))
    return []


def value(row, key):
    return (row.get(key) or {}).get("value")


def clean_date(text):
    if not text:
        return None
    match = re.match(r"(\d{4})-(\d{2})-(\d{2})", text)
    if not match:
        return None
    year = int(match.group(1))
    if not 1930 <= year <= 2012:
        return None
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"


def clean_height(text):
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if number < 3:
        number *= 100
    if 130 <= number <= 210:
        return int(round(number))
    return None


def ascii_fold(text):
    normalized = unicodedata.normalize("NFKD", text or "")
    return "".join(char for char in normalized if not unicodedata.combining(char))


def clean_handle(value_text):
    text = (value_text or "").strip()
    if not text:
        return None
    if text.startswith("http"):
        path = urllib.parse.urlparse(text).path.strip("/")
        return path.split("/")[0] or None
    return text.lstrip("@")


def build():
    os.makedirs(RAW, exist_ok=True)
    merged: dict[str, dict] = {}
    max_chunks = int(os.environ.get("WD_MAX_CHUNKS") or MAX_CHUNKS)
    for index in range(max_chunks):
        offset = index * CHUNK
        rows = query_page(offset)
        print(f"  第 {index + 1} 段（offset {offset}）：{len(rows)} 行", flush=True)
        if not rows:
            break
        for row in rows:
            qid_url = value(row, "p")
            if not qid_url:
                continue
            qid = qid_url.rsplit("/", 1)[-1]
            countries = []
            country = value(row, "countryLabel")
            if country:
                countries.append(country)
            entry = merged.setdefault(qid, {
                "qid": qid, "labels": {}, "countries": set(),
                "birth": None, "height": None,
                "socials": {}, "official_site": None, "imdb": None,
            })
            for key in ("en", "ja", "zh", "ko"):
                label = value(row, key)
                if label:
                    entry["labels"].setdefault(key, label)
            entry["countries"].update(countries)
            entry["birth"] = entry["birth"] or clean_date(value(row, "birth"))
            entry["height"] = entry["height"] or clean_height(value(row, "height"))
            for platform, key in (("instagram", "ig"), ("twitter", "tw"),
                                  ("youtube", "yt")):
                handle = clean_handle(value(row, key))
                if handle and platform not in entry["socials"]:
                    entry["socials"][platform] = handle
            site = value(row, "site")
            if site and not entry["official_site"]:
                entry["official_site"] = site
            imdb = value(row, "imdb")
            if imdb and not entry["imdb"]:
                entry["imdb"] = imdb
        if len(rows) < CHUNK:
            break
        time.sleep(65)

    records = []
    for entry in merged.values():
        regions = [COUNTRY_REGION[c.casefold()] for c in entry["countries"]
                   if c.casefold() in COUNTRY_REGION]
        if not regions:
            continue
        # 有欧美国籍时优先按 western：这批人主要活跃在欧美，
        # 若按亚裔国籍归档会被「只补已有」挡掉，也容易和中文译名拆成两条。
        priority = ["western", "japan", "korea", "taiwan", "hongkong", "china"]
        region = next((item for item in priority if item in regions), "western")
        labels = entry["labels"]
        preference = {
            "japan": ("ja", "zh", "en", "ko"),
            "korea": ("ko", "en", "zh", "ja"),
            "taiwan": ("zh", "en", "ja", "ko"),
            "hongkong": ("zh", "en", "ja", "ko"),
            "china": ("zh", "en", "ja", "ko"),
            "western": ("en", "zh", "ja", "ko"),
        }[region]
        name = next((labels[key] for key in preference if labels.get(key)), None)
        if not name:
            continue
        names = []
        for key, label in labels.items():
            if label and label != name and label not in names:
                names.append(label)
        folded = ascii_fold(name)
        if folded and folded != name and folded not in names:
            names.append(folded)
        if not (entry["birth"] or entry["height"] or entry["socials"]
                or entry["official_site"]):
            # 没有任何可补字段：日本/韩国等走「只补已有」的源没有价值，跳过。
            continue
        records.append({
            "qid": entry["qid"],
            "name": name,
            "names": names,
            "region": region,
            "birth_date": entry["birth"],
            "height": entry["height"],
            "socials": entry["socials"],
            "official_site": entry["official_site"],
            "imdb": entry["imdb"],
            "source": "wikidata",
            "source_url": f"https://www.wikidata.org/wiki/{entry['qid']}",
        })
    records.sort(key=lambda row: (row["region"], row["name"]))
    tmp = OUT + ".tmp"
    json.dump(records, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)
    from collections import Counter
    counts = Counter(row["region"] for row in records)
    print(f"完成：{len(records)} 人 {dict(counts)} → {OUT}")


if __name__ == "__main__":
    build()
