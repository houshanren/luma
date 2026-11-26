#!/usr/bin/env python3
"""抓取华语 Coser / 写真模特 / 福利姬的公开档案，补国内人物字段。

用法：python3 Tools/catalog_build/fetch/fetch_cn_profiles.py
输出：Tools/catalog_build/raw/cn_profiles_web.json

站点（全部为公开页面，只取文字档案与作品目录，不下载图片）：
- coshe.net      WordPress REST，约 500 位 Coser，含个人介绍 + 合集目录
- 52cos.cc       WordPress REST，约 1000 位 Coser，含档案散文 + 目录
- xiuren.live    秀人系模特，约 500 位，含生日 / 身高 / 三围 / 出生地 / 社交

注意：这些站点自己声明资料来自「互联网公开整合」，只做参考；
解析只记录明确写出的数字与链接，解析不出来就留空，不做推测。
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
OUT = os.path.join(RAW, "cn_profiles_web.json")
PROXIES = {"http": "http://127.0.0.1:8118", "https": "http://127.0.0.1:8118"}

SESSION = requests.Session()
SESSION.proxies.update(PROXIES)
SESSION.headers.update({
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"),
    "Accept": "text/html,application/json",
})

SOCIAL_PATTERNS = {
    "weibo": r"https?://(?:www\.)?weibo\.com/(?:u/)?([A-Za-z0-9_\-]{4,40})",
    "bilibili": r"https?://(?:space\.)?bilibili\.com/(\d{4,12})",
    "twitter": r"https?://(?:www\.)?(?:twitter|x)\.com/([A-Za-z0-9_]{2,30})",
    "instagram": r"https?://(?:www\.)?instagram\.com/([A-Za-z0-9_.]{2,30})",
    "douyin": r"抖音号?[：:]\s*([A-Za-z0-9_.]{3,30})",
    "xiaohongshu": r"小红书号?[：:]\s*([A-Za-z0-9_.]{3,30})",
}

SOCIAL_BLOCK = {"share", "login", "signup", "home", "explore", "search", "p", "u"}

GENERIC_TAGS = {"cos", "cosplay", "coser", "网红", "美女", "写真", "图集", "模特", "博主"}
# 合集站里不少文章标题是「某人 COSPLAY写真作品 - 角色」，不是人物档案页。
NON_PERSON_NAME = re.compile(
    r"(COSPLAY|写真作品|图片包|合集|更新至|全套|会员|首页|登录|公告|免费福利|"
    r"是什么意思|是什么梗|网络用语|网络热词|热词|百科|怎么读|为什么|有哪些)")


def looks_like_person(name):
    value = name or ""
    if NON_PERSON_NAME.search(value) or " - " in value:
        return False
    if re.search(r"(充电|付费|在线视频|图片视频|视频合集)", value):
        return False
    return True


def clean_text(value):
    text = re.sub(r"<script.*?</script>", "", value or "", flags=re.S | re.I)
    text = re.sub(r"<style.*?</style>", "", text, flags=re.S | re.I)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"</(?:p|div|h\d|li|tr)>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    return text


def clean_lines(text):
    lines = [(line or "").strip() for line in text.splitlines()]
    return [line for line in lines if line]


def first_image(raw_html):
    for match in re.finditer(r"<img[^>]+(?:data-src|src)=[\"']([^\"']+)[\"']", raw_html or "", re.I):
        url = match.group(1)
        if url.startswith("data:"):
            continue
        if any(word in url.lower() for word in ("avatar", "logo", "icon", "loading", "placeholder")):
            continue
        return url
    return None


def parse_birth(text):
    match = re.search(r"生日[^0-9]{0,6}((?:19|20)\d{2})\s*[-年./]\s*(\d{1,2})\s*[-月./]\s*(\d{1,2})", text)
    if not match:
        match = re.search(r"出生[^0-9]{0,8}((?:19|20)\d{2})\s*[-年./]\s*(\d{1,2})\s*[-月./]\s*(\d{1,2})", text)
    if not match:
        # 人物档案开头常直接写「某某，1993年6月10日出生于上海」，没有「生日」二字。
        match = re.search(r"((?:19|20)\d{2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日", text[:800])
    if not match:
        return None
    year, month, day = (int(part) for part in match.groups())
    if not (1940 <= year <= 2012 and 1 <= month <= 12 and 1 <= day <= 31):
        return None
    return f"{year:04d}-{month:02d}-{day:02d}"


def parse_number(text, *words, low, high):
    for word in words:
        match = re.search(rf"{word}[^0-9]{{0,6}}(\d{{2,3}})", text)
        if match:
            value = int(match.group(1))
            if low <= value <= high:
                return value
    return None


def parse_measurements(text):
    match = re.search(
        r"(?:三围|BWH)[^0-9B]{0,8}B?\s*(\d{2,3})\s*[-/–—\s]+[Ww]?\s*(\d{2,3})\s*[-/–—\s]+[Hh]?\s*(\d{2,3})",
        text, re.I)
    if not match:
        return None, None, None
    bust, waist, hips = (int(part) for part in match.groups())
    if not all(40 <= value <= 160 for value in (bust, waist, hips)):
        return None, None, None
    if bust <= waist:
        return None, None, None
    return bust, waist, hips


PLACE_ROLE = re.compile(r"(平面模特|动漫博主|模特|博主|网红|女孩|女生|美女|主播|演员|Coser)$", re.I)


def normalize_place(value):
    if not value:
        return None
    text = re.sub(r"^中国", "", str(value).strip())
    text = re.split(r"[的，,。]", text)[0].strip()
    text = re.sub(r"(?:在|是)?(?:微博|B站|抖音|小红书)", "", text)
    text = PLACE_ROLE.sub("", text).strip()
    return text if len(text) >= 2 else None


def parse_birthplace(text):
    patterns = (
        r"出生地[：:]\s*(?:中国)?\s*([\u4e00-\u9fa5]{2,12})",
        r"出生于(?:中国)?\s*([\u4e00-\u9fa5]{2,12})",
        r"来自(?:中国)?\s*([\u4e00-\u9fa5]{2,12})",
        r"出\s*生[：:]\s*(?:中国)?\s*([\u4e00-\u9fa5]{2,12})",
        r"籍贯[：:]\s*(?:中国)?\s*([\u4e00-\u9fa5]{2,12})",
    )
    for pattern in patterns:
        match = re.search(pattern, text)
        if not match:
            continue
        value = match.group(1).strip()
        value = re.split(r"(?:职|兴|生日|身高|星座|三围|体重|现居)", value)[0]
        value = normalize_place(value)
        if value and value not in {"中国", "国内", "大陆"} and len(value) >= 2:
            return value
    return None


def parse_socials(text):
    socials = {}
    for source, pattern in SOCIAL_PATTERNS.items():
        match = re.search(pattern, text, re.I)
        if not match:
            continue
        handle = match.group(1)
        if handle.lower() in SOCIAL_BLOCK:
            continue
        socials[source] = {"handle": handle, "url": match.group(0)}
    return socials


def parse_tags(text):
    tags = []
    for tag in ("福利姬", "网红", "Coser", "写真", "模特", "主播", "动漫博主"):
        if tag.lower() in text.lower() and tag not in tags:
            tags.append(tag)
    return tags


def split_name(raw):
    """『桜井宁宁(宁宁子同学)』→ 主名 + 别名；『绯月樱Cherry · 谢芷馨』同样拆开。"""
    raw = (raw or "").strip()
    if not raw:
        return None, []
    aliases = []
    for match in re.finditer(r"[（(]([^）)]{2,20})[）)]", raw):
        alias = match.group(1).strip()
        if alias and alias not in aliases:
            aliases.append(alias)
    name = re.sub(r"[（(][^）)]{1,30}[）)]", "", raw).strip()
    if "·" in name:
        head, tail = name.split("·", 1)
        head, tail = head.strip(), tail.strip()
        if head and tail:
            name = head
            if tail not in aliases:
                aliases.append(tail)
    name = name.strip(" -–—|")
    return (name or None), aliases


def parse_works(lines, name):
    """从「合集目录 / No.xxx」列表里取作品标题。"""
    works = []
    for line in lines:
        match = re.search(r"(?:No\.?|NO\.?)\s*0*(\d{1,4})?\s*[-–—.、:：]?\s*(.+?)\s*\[(\d+)\s*P",
                          line)
        if not match:
            continue
        title = match.group(2).strip(" -–—.、:：")
        if not title or len(title) > 80:
            continue
        if title == name:
            continue
        works.append({
            "no": int(match.group(1)) if match.group(1) else None,
            "title": title,
            "images": int(match.group(3)),
        })
    return works


def pick_summary(lines, name):
    best = None
    for line in lines:
        if len(line) < 30 or len(line) > 600:
            continue
        if any(word in line for word in ("目录", "部分预览", "合集目录", "如需关注", "本期由")):
            continue
        if re.search(r"(?:No\.?|NO\.?)\s*0*\d{1,4}\s*.{0,60}\[\d+\s*P", line):
            continue
        if best is None or len(line) > len(best):
            best = line
    if not best:
        return None
    best = re.sub(r"\s+", " ", best)
    return best[:300]


def clean_title_name(title):
    """去掉标题里的序号与站点后缀：『043-不呆猫[更新至 82 期]』→『不呆猫』。"""
    name = (title or "").strip()
    name = re.sub(r"^\s*\d{2,4}\s*[-–—.、]\s*", "", name)
    name = re.sub(r"\s*\[[^\]]*\]\s*$", "", name)
    name = re.sub(r"^\s*B站UP主\s*[-－—]?\s*", "", name, flags=re.I)
    name = re.sub(r"^\s*B站\s*", "", name)
    name = re.split(r"[-－—](?:精选)?(?:视频|图片|cosplay|COS|写真|合集)", name, flags=re.I)[0]
    name = re.sub(r"(?:付费)?充电.*$", "", name)
    name = re.sub(r"(?:在线)?视频.*$", "", name)
    name = re.sub(r"图片.*$", "", name)
    name = re.sub(r"写真$", "", name)
    name = re.sub(r"\s*[-–—]\s*COSPLAY.*$", "", name, flags=re.I)
    name = re.sub(r"\s*[-–—]\s*写真.*$", "", name)
    return name.strip()


def add_record(records, raw_name, source, source_url, lines, raw_html, title_hint=None):
    name, aliases = split_name(clean_title_name(raw_name))
    if not name or len(name) > 30:
        return
    if not looks_like_person(name):
        return
    joined = "\n".join(lines)
    birthday = parse_birth(joined) or parse_birth(title_hint or "")
    height = parse_number(joined, "身\\s*高", low=140, high=190)
    weight = parse_number(joined, "体重", low=35, high=80)
    bust, waist, hips = parse_measurements(joined)
    record = {
        "name": name,
        "raw_title": (title_hint or "").strip() or None,
        "aliases": aliases,
        "region": "china",
        "birth_date": birthday,
        "height": height,
        "weight": weight,
        "bust": bust,
        "waist": waist,
        "hips": hips,
        "birthplace": parse_birthplace(joined),
        "tags": parse_tags(joined),
        "summary": pick_summary(lines, name),
        "socials": parse_socials(joined + "\n" + (raw_html or "")),
        "image_url": first_image(raw_html),
        "source": source,
        "source_url": source_url,
        "works": parse_works(lines, name),
    }
    if not any(record.get(field) for field in
               ("birth_date", "height", "weight", "bust", "birthplace", "image_url", "summary")):
        return
    records.append(record)


def fetch_json(url, tries=5):
    for attempt in range(tries):
        try:
            response = SESSION.get(url, timeout=45)
            if response.status_code == 200:
                return response.json()
            if response.status_code == 404:
                return None
            time.sleep(3 * (attempt + 1))
        except (requests.RequestException, ValueError) as error:
            print(f"    失败 {type(error).__name__}，重试 {attempt + 1}/{tries}")
            time.sleep(3 * (attempt + 1))
    return None


def fetch_wp(base, records, source):
    page = 1
    while True:
        url = (f"{base}/wp-json/wp/v2/posts?per_page=100&page={page}"
               f"&_fields=id,title,link,content")
        data = fetch_json(url)
        if not data:
            break
        for post in data:
            title = html.unescape(re.sub(r"<[^>]+>", "", (post.get("title") or {}).get("rendered", "")))
            content = (post.get("content") or {}).get("rendered", "")
            lines = clean_lines(clean_text(content))
            add_record(records, raw_name=title, source=source,
                       source_url=post.get("link") or "", lines=lines, raw_html=content,
                       title_hint=title)
        print(f"  {source} 第 {page} 页，累计 {len(records)} 条")
        if len(data) < 100:
            break
        page += 1
        time.sleep(1.2)


def fetch_xiuren(records):
    sitemap = SESSION.get("https://www.xiuren.live/sitemap.xml", timeout=45).text
    urls = [url for url in re.findall(r"<loc>(.*?)</loc>", sitemap) if "model-" in url]
    for position, url in enumerate(urls, 1):
        try:
            response = SESSION.get(url, timeout=45)
            if response.status_code != 200:
                continue
            page = response.text
        except requests.RequestException:
            time.sleep(2)
            continue
        match = re.search(r"<h1[^>]*>(.*?)</h1>", page, re.S)
        title = html.unescape(re.sub(r"<[^>]+>", "", match.group(1))).strip() if match else ""
        body = re.sub(r"<script.*?</script>", "", page, flags=re.S | re.I)
        body = re.sub(r"<style.*?</style>", "", body, flags=re.S | re.I)
        lines = clean_lines(clean_text(body))
        add_record(records, raw_name=title, source="xiuren",
                   source_url=url, lines=lines, raw_html=page)
        if position % 50 == 0:
            print(f"  xiuren {position}/{len(urls)}，累计 {len(records)} 条")
        time.sleep(0.8)


def main():
    os.makedirs(RAW, exist_ok=True)
    records: list[dict] = []
    fetch_wp("https://www.coshe.net", records, "coshe")
    fetch_wp("https://www.52cos.cc", records, "52cos")
    try:
        fetch_xiuren(records)
    except Exception as error:  # 单站失败不影响已抓到的结果
        print(f"  xiuren 抓取中断：{type(error).__name__}")
    json.dump(records, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    with_data = sum(1 for r in records if r.get("birth_date") or r.get("height"))
    print(f"完成：{len(records)} 条，其中有生日/身高 {with_data} 条 → {OUT}")


if __name__ == "__main__":
    main()
