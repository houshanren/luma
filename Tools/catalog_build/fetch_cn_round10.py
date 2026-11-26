#!/usr/bin/env python3
"""P0/P1 新源：秀人官方镜像 / jvheku / 艺图湾 / 七图社 / 颜蜜社。

用法：
    python3 Tools/catalog_build/fetch_cn_round10.py
    CN_ROUND10_SITES=myxiuren CN_ROUND10_MAX_PAGES=2 python3 ...  # 小样验证

输出（Tools/catalog_build/raw）：
- cn_profiles_myxiuren.json   秀人网官方镜像（人名标签 + 单套作品）
- cn_profiles_jvheku.json     jvheku 韩系 web pictorial / 微密圈（标题取人名）
- cn_profiles_yituwan.json    艺图湾（机构标签里的真人名 + 单套作品）
- cn_profiles_guoxuezy.json   七图社（微密圈 / 抖音网红）
- cn_profiles_yanmishe.json   颜蜜社（与七图社同源）
- cn_studios_yituwan.json     艺图湾机构标签 → 写真机构

去重口径：
1. 站方机构 / 系列 / 泛词标签不当人名（ORG / GENERIC 清单）。
2. 新名若是「库内纯中文名 + 字母尾缀」，归一到库内主名（复用 xiurenwang 的规则）。
3. 同一站内同名合并；作品按 URL 去重，单人物最多留 400 条。
4. 作品是否跨站重复交给 build_catalog_db.py 的「NO. + 标题指纹」统一处理。
只取文字目录与封面 URL，不下载图片。
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import time
from urllib.parse import urlparse

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_xiurenwang as xw  # noqa: E402  复用名字清洗 / 库内归一

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
CACHE = os.path.join(RAW, ".cn_round10")

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"),
    "Accept-Language": "zh-CN,zh;q=0.9",
})

SITES = [
    {"key": "myxiuren", "base": "https://www.myxiuren.com",
     "out": "cn_profiles_myxiuren.json", "names": "tags", "works": True,
     "tag": "秀人网", "cover_limit": 500, "title_fallback": False},
    {"key": "jvheku", "base": "https://www.jvheku.com",
     "out": "cn_profiles_jvheku.json", "names": "title", "works": True,
     "tag": "写真模特", "cover_limit": 700},
    {"key": "yituwan", "base": "https://www.yituwan.com",
     "out": "cn_profiles_yituwan.json", "names": "tags", "works": True,
     "tag": "写真模特", "cover_limit": 600, "title_fallback": False,
     "tag_must_match_title": True,
     "studios": "cn_studios_yituwan.json"},
    {"key": "guoxuezy", "base": "https://guoxuezy.cn",
     "out": "cn_profiles_guoxuezy.json", "names": "tags", "works": False,
     "tag": "微密圈", "cover_limit": 450, "title_fallback": False,
     "tag_must_match_title": True},
    {"key": "yanmishe", "base": "https://yanmishe.cn",
     "out": "cn_profiles_yanmishe.json", "names": "tags", "works": False,
     "tag": "微密圈", "cover_limit": 450, "title_fallback": False,
     "tag_must_match_title": True},
]

# 韩系机构：标题/标签里出现时，该帖人物判为韩国。
KOREAN_ORGS = {
    "bimilstory", "bimilstory(韩国)", "leeheeexpress", "leehee express",
    "pure media", "puremedia", "loozy", "artgravia", "djawa", "djawas",
    "韩国写真", "韩国模特", "seeshe", "r.q*play", "rq play",
}

# 站方机构 / 系列标签（在 xiurenwang 的基础上补本轮新站）。
EXTRA_ORGS = {
    "绣人网", "秀人网", "微密圈", "觅圈", "铁粉空间", "秘语空间", "岛遇", "幻宇星球",
    "爱尤物", "爱油物", "尤果网", "ugirls", "美媛馆", "mygirl美媛馆", "花漾",
    "huayang花漾", "语画界", "尤蜜荟", "youmi尤蜜荟", "爱蜜社", "星颜社", "魅妍社",
    "蜜桃社", "波萝社", "果团网", "秘密花园", "青柠映画", "美图馆", "推女郎",
    "推女神", "优星馆", "美丝社", "街拍", "物恋传媒", "丝享家", "异思趣向",
    "beautyleg", "ligui丽柜", "丽柜", "慕丝女郎", "ssa丝社", "克拉女神", "袜啵啵",
    "丝慕写真", "嗲囡囡", "森萝财团", "甜予摄影", "只糖棉袜", "风之领域",
    "一千零一夜", "大生模拍", "sihua思话", "普惠集", "丝族便当", "ishow爱秀",
    "siee丝意", "mfstar模范学苑", "feilin", "n5次元", "潮图集", "狐樱社",
    "影语阁", "乐妖图", "图罗记", "喵风向", "元气领域", "虾仁猪心", "女神空",
    "袜觅社", "品多多", "盘丝PANS", "YouMi尤蜜", "BoBoSocks袜啵啵",
    "品多多/K&M",
    "微密", "微密合集", "其他机构", "精选单套", "写真机构", "新自媒体",
    "视觉名模", "平面名模", "私房人像", "私房写真", "室内私影", "摄影合集",
    "写真合集", "高清写真", "微密圈写真", "微密圈作品", "cosplay", "cos",
    "金克丝", "金融股票", "软件下载", "电脑",
}

GENERIC = {
    "性感", "美女", "美人", "尤物", "少妇", "巨乳", "爆乳", "豪乳", "翘臀",
    "女神", "黑丝", "白丝", "肉丝", "丝袜", "美腿", "美臀", "美乳", "美胸",
    "诱惑", "写真", "嫩模", "御姐", "妹子", "mm", "情趣", "私房", "湿身",
    "车模", "街拍", "视频", "套图", "图集", "合集", "合辑", "模特", "新人",
    "精选", "内购", "无水印", "福利", "美图", "高清", "大图", "头像", "壁纸",
    "主播", "网红", "少女", "学生", "护士", "空姐", "秘书", "教师", "女仆",
    "萝莉", "人妻", "熟女", "泳装", "自拍", "露出", "大尺度", "胴体", "欲女",
    "肥臀", "校花", "搔首弄姿", "女王", "真空", "长腿", "巨臀", "清纯", "玉女",
    "学生妹", "丰臀", "兔女郎", "丁字裤", "制服诱惑", "内衣秀", "性感写真",
    "性感图片", "宅男女神", "美少女", "福利姬", "微密圈", "作品特点", "艺术",
    "创意", "动漫博主", "摄影师", "更新", "新品", "原创", "转载", "最新",
    "短裙", "短裤", "包臀裙", "热裤", "紧身裤", "长裙", "连衣裙", "睡裙",
    "吊带", "吊带袜", "连裤袜", "白丝袜", "黑丝袜", "美脚", "美足", "高跟鞋",
    "泳衣", "文胸", "蕾丝", "制服", "丝袜美腿", "大长腿", "长腿美女",
}

DATE_HEAD = re.compile(r"^\s*(?:\[[^\]]{1,40}\]|【[^】]{1,40}】|\d{4}[.\-/年]\d{1,2}[.\-/月]\d{1,2}日?)\s*")
DASH = re.compile(r"\s+[–—\-－]\s+")
AGGREGATE = re.compile(r"(全套|合集|合辑|持续更新|资源汇总|汇总|打包|目录|整理)")
ALBUM_HINT = re.compile(r"((?:NO|No|no)\.?\s*\d{1,5}|\d+\s*[Pp]\s*\d*\s*[Vv]?)")
# 韩系合集的模特名常在编号后或方括号里：`LEHF-089A Q.Na [62P...]` / `LERB-100 [Hana]`。
KOREAN_BRACKET = re.compile(r"\[([A-Za-z][A-Za-z0-9 .&_-]{1,20})\]\s*$")
KOREAN_AFTER_CODE = re.compile(r"LE[A-Z]{2,3}-\d{2,4}[A-Z]?\s+(.{2,24}?)\s*[\[\(（]")
# jvheku 是混合博客：只有「人名 – 全套/合集/NO./微密圈…」这种资源标题才当人物，
# 否则「电脑录屏工具 – 下载」也会被当成模特（曾一次跑出 5,000 个假人）。
JV_TITLE = re.compile(
    r"^\s*(.{2,24}?)\s+[–—]\s*(?:全套|合[集辑]|NO\.|No\.|微密圈|内购|写真|视频|图片|更新|私房|福利)")
COUNT_HINT = re.compile(r"(\d{1,4})\s*(?:套|期)")
HANGUL = re.compile(r"[\uac00-\ud7af]")
KANA = re.compile(r"[ぁ-んァ-ヶ]")
CJK = re.compile(r"[\u4e00-\u9fa5]")
IMG_RE = re.compile(
    r'<img[^>]+(?:data-src|src)="([^"]+?\.(?:jpg|jpeg|png|webp))"', re.I)
ORG_SUFFIX = re.compile(
    r"(社|馆|館|网|網|传媒|摄影|工作室|学院|财团|画报|映像|视觉|女郎|丝社|写真|"
    r"合辑|合集|机构|出品|工坊|影画|映像|公司|集团)$")
JUNK_NAME = re.compile(
    r"(下载|资源|地址|官网|app|视频|合集|软件|图包|网盘|百度|夸克|解压|密码|"
    r"拍照|升职记|记录|日记|日常|旅行|写真书)", re.I)


def fetch_json(url, tries=4):
    for attempt in range(tries):
        try:
            response = SESSION.get(url, timeout=30)
            if response.status_code == 200:
                return response.json(), response.headers
            if response.status_code in (400, 401, 404):
                return None, response.headers
            time.sleep(1.2 * (attempt + 1))
        except (requests.RequestException, ValueError):
            time.sleep(1.2 * (attempt + 1))
    return None, {}


def fetch_text(url, tries=3):
    for attempt in range(tries):
        try:
            response = SESSION.get(url, timeout=30)
            if response.status_code == 200:
                return response.text
            if response.status_code in (401, 404):
                return None
            time.sleep(1.0 * (attempt + 1))
        except requests.RequestException:
            time.sleep(1.0 * (attempt + 1))
    return None


def is_org(name):
    value = (name or "").strip()
    if not value:
        return True
    lowered = value.casefold()
    if lowered in KOREAN_ORGS or lowered in {v.casefold() for v in EXTRA_ORGS}:
        return True
    if value in GENERIC or lowered in GENERIC:
        return True
    if xw.is_org_name(value):
        return True
    if JUNK_NAME.search(value):
        return True
    if ORG_SUFFIX.search(value):
        return True
    if re.search(r"(写真|图集|套图|视频|合集|机构|传媒|摄影|模特)$", value):
        return True
    return False


def looks_like_person(name):
    value = (name or "").strip()
    if not value or len(value) > 24:
        return False
    if re.fullmatch(r"[\d\s.\-]+", value):
        return False
    if not (CJK.search(value) or re.search(r"[A-Za-z]{2,}", value)):
        return False
    if is_org(value):
        return False
    return True


def clean_name(raw):
    value = html.unescape(raw or "").strip()
    value = DATE_HEAD.sub("", value).strip(" -–—|·")
    if not value:
        return None, []
    name, aliases = xw.clean_person_name(value)
    if not name:
        # 站方标签常带括号别名，clean_person_name 偶发过严时退回轻量判断。
        match = re.fullmatch(r"(.{2,24}?)\s*[（(]([^）)]{2,30})[）)]", value)
        if match and looks_like_person(match.group(1)):
            name, aliases = match.group(1).strip(), [match.group(2).strip()]
        elif looks_like_person(value):
            name, aliases = value, []
    if not name:
        return None, []
    if is_org(name):
        return None, []
    aliases = [alias for alias in aliases if not is_org(alias)]
    return name, aliases


def name_from_title(title):
    text = html.unescape(re.sub(r"<[^>]+>", "", title or "")).strip()
    head = DASH.split(text, maxsplit=1)[0] if DASH.search(text) else text
    head = DATE_HEAD.sub("", head).strip()
    if not head or ALBUM_HINT.search(head) or AGGREGATE.search(head):
        return None, []
    return clean_name(head)


def korean_name_from_title(title):
    """韩系合集：机构名在标题开头，真人名在编号后 / 末尾方括号里。"""
    text = html.unescape(re.sub(r"<[^>]+>", "", title or "")).strip()
    for regex in (KOREAN_AFTER_CODE, KOREAN_BRACKET):
        match = regex.search(text)
        if not match:
            continue
        name, aliases = clean_name(match.group(1))
        if name:
            return name, aliases
    return None, []


def jvheku_name_from_title(title):
    """jvheku：先认「人名 – 资源后缀」，再退回韩系编号/方括号里的名字。"""
    text = html.unescape(re.sub(r"<[^>]+>", "", title or "")).strip()
    match = JV_TITLE.match(text)
    if match:
        name, aliases = clean_name(match.group(1))
        if name:
            return name, aliases
    return korean_name_from_title(text)


def region_for(name, aliases, site_key, korean_hint=False):
    probe = f"{name} {' '.join(aliases)}"
    if HANGUL.search(probe):
        return "korea"
    if KANA.search(probe):
        return "japan"
    if site_key == "jvheku" and korean_hint:
        return "korea"
    return "china"


def cover_of(page_html):
    if not page_html:
        return None
    for url in IMG_RE.findall(page_html):
        if re.search(r"(logo|icon|avatar|favicon|advert|banner)", url, re.I):
            continue
        host = urlparse(url).netloc.lower()
        if "wp-content/uploads" in url or host.startswith("pic."):
            return url if url.startswith("http") else f"https:{url}"
    return None


def fetch_tags(site):
    tags = {}
    base = site["base"]
    page = 1
    while page <= 80:
        data, _ = fetch_json(
            f"{base}/wp-json/wp/v2/tags?per_page=100&page={page}"
            "&orderby=count&order=desc&_fields=id,name,count,link")
        if not data:
            break
        for tag in data:
            tags[tag["id"]] = tag
        if len(data) < 100:
            break
        page += 1
        time.sleep(0.2)
    return tags


def iter_posts(site, max_pages=None):
    base = site["base"]
    key = site["key"]
    cache_dir = os.path.join(CACHE, key)
    os.makedirs(cache_dir, exist_ok=True)
    page = 1
    total_pages = None
    while True:
        cache_path = os.path.join(cache_dir, f"p{page:04d}.json")
        if os.path.exists(cache_path):
            data = json.load(open(cache_path, encoding="utf-8"))
            headers = {}
        else:
            data, headers = fetch_json(
                f"{base}/wp-json/wp/v2/posts?per_page=100&page={page}"
                "&_fields=id,title,link,tags,date")
            if data:
                json.dump(data, open(cache_path, "w", encoding="utf-8"),
                          ensure_ascii=False)
        if not data:
            break
        if total_pages is None:
            try:
                total_pages = int(headers.get("X-WP-TotalPages", 0))
            except (TypeError, ValueError):
                total_pages = 0
            print(f"  {key} 共 {total_pages or '?'} 页", flush=True)
        yield data
        if max_pages and page >= max_pages:
            break
        if total_pages and page >= total_pages:
            break
        if len(data) < 100:
            break
        page += 1
        time.sleep(0.12)


def canonical_name(name, table):
    """新名 → 库内主名：先按 xiurenwang 的字母尾缀规则，再补「库内 CJK+拉丁」的短前缀。

    「鱼子酱」对库内「鱼子酱Fish」是同一个人；「安然Maleah」不会被并到
    「安然anran」，因为要求新名本身是库内名的前缀，而不是反过来。
    """
    canonical = xw.canonical_for(name, table)
    if canonical:
        return canonical
    key = xw.normalize_name(name)
    if not key:
        return None
    candidates = set()
    for library_key, value in table.items():
        if not library_key.startswith(key):
            continue
        suffix = library_key[len(key):]
        if 2 <= len(suffix) <= 6 and re.fullmatch(r"[a-z0-9]+", suffix):
            candidates.add(value)
    return candidates.pop() if len(candidates) == 1 else None


def tag_matches_title(tag, title):
    """标签是否真的出现在标题里：聚合站的题材/地点标签大多不会进标题。"""
    tag_key = xw.normalize_name(tag)
    if not tag_key:
        return False
    if tag_key in xw.normalize_name(title):
        return True
    core = "".join(re.findall(r"[\u4e00-\u9fa5A-Za-z]{2,}", tag))
    return bool(core and core.casefold() in (title or "").casefold())


def build_site(site, max_pages=None):
    key = site["key"]
    print(f"\n== {key} ==", flush=True)
    tags = fetch_tags(site) if site["names"] == "tags" else {}
    people: dict[str, dict] = {}
    first_post: dict[str, str] = {}
    post_count = 0
    for posts in iter_posts(site, max_pages):
        for post in posts:
            post_count += 1
            title = html.unescape(re.sub(r"<[^>]+>", "",
                                         (post.get("title") or {}).get("rendered", ""))).strip()
            url = post.get("link") or ""
            post_tags = [tags[tid]["name"] for tid in post.get("tags") or [] if tid in tags]
            korean_hint = bool(re.search(r"(韩国|bimilstory|leehee|pure media|djaw)", title, re.I)
                               or any(t.casefold() in KOREAN_ORGS for t in post_tags))
            names = []
            if site["names"] == "tags":
                for tag_name in post_tags:
                    if site.get("tag_must_match_title") and not tag_matches_title(tag_name, title):
                        continue
                    name, aliases = clean_name(tag_name)
                    if name and not any(n == name for n, _ in names):
                        names.append((name, aliases))
            if not names and key == "jvheku":
                name, aliases = jvheku_name_from_title(title)
                if name:
                    names.append((name, aliases))
            if not names and key != "jvheku" and site.get("title_fallback", True):
                name, aliases = name_from_title(title)
                if name:
                    names.append((name, aliases))
            if not names:
                continue
            aggregate = bool(AGGREGATE.search(title))
            is_album = bool(ALBUM_HINT.search(title))
            add_work = site["works"] and not aggregate and (key != "jvheku" or is_album)
            count_hint = COUNT_HINT.search(title)
            album_count = int(count_hint.group(1)) if count_hint else None
            for name, aliases in names:
                record = people.setdefault(name, {
                    "aliases": [], "works": [], "image_url": None,
                    "region_hint": None, "album_count": 0,
                })
                for alias in aliases:
                    if alias and alias != name and alias not in record["aliases"]:
                        record["aliases"].append(alias)
                if korean_hint:
                    record["region_hint"] = "korea"
                if add_work and url:
                    record["works"].append({"no": None, "title": title[:160], "url": url})
                if album_count:
                    record["album_count"] = max(record["album_count"], album_count)
                first_post.setdefault(name, url)
        if post_count and post_count % 2000 == 0:
            print(f"  已处理 {post_count} 篇，人物 {len(people)}", flush=True)

    print(f"  帖子 {post_count}，人物 {len(people)}，开始取封面…", flush=True)
    table = xw.library_names()
    canonical: dict[str, dict] = {}
    merged = 0
    for name, record in people.items():
        target_name = canonical_name(name, table) or name
        if target_name != name:
            merged += 1
        target = canonical.setdefault(target_name, {
            "aliases": [], "works": [], "image_url": None,
            "region_hint": None, "album_count": 0,
        })
        if target_name != name:
            target["aliases"].append(name)
        for alias in record["aliases"]:
            if alias != target_name and alias not in target["aliases"]:
                target["aliases"].append(alias)
        target["works"].extend(record["works"])
        target["region_hint"] = target["region_hint"] or record["region_hint"]
        target["album_count"] = max(target["album_count"], record["album_count"])

    # 艺图湾是 6.5 万篇的聚合站：库外人名只保留至少 3 套作品的，
    # 否则「古镇拍照」「三蜜升职记」这类题材标签会灌进几千个假人。
    if key == "yituwan":
        canonical = {
            name: record for name, record in canonical.items()
            if xw.normalize_name(name) in table or len(record["works"]) >= 3
        }

    # 封面：每个新人物只抓一次详情页，取正文第一张图。
    limit = site.get("cover_limit", 400)
    targets = []
    for name, record in canonical.items():
        if len(targets) >= limit:
            break
        if record["image_url"]:
            continue
        page_url = first_post.get(name) or next(
            (work["url"] for work in record["works"]), None)
        if page_url:
            targets.append((name, page_url))
    from concurrent.futures import ThreadPoolExecutor

    def grab(item):
        name, page_url = item
        return name, cover_of(fetch_text(page_url))

    with ThreadPoolExecutor(max_workers=8) as pool:
        for index, (name, cover) in enumerate(pool.map(grab, targets), 1):
            canonical[name]["image_url"] = cover
            if index % 200 == 0:
                print(f"  封面 {index}/{len(targets)}", flush=True)

    records = []
    for name, record in canonical.items():
        works, seen = [], set()
        for work in record["works"]:
            if work["url"] in seen:
                continue
            seen.add(work["url"])
            works.append(work)
        aliases = [alias for alias in record["aliases"] if alias != name]
        region = region_for(name, aliases, key, record["region_hint"] == "korea")
        tags_out = [site["tag"]] if site.get("tag") else []
        if not CJK.search(name) and not KANA.search(name) and not HANGUL.search(name):
            tags_out.append("网红")
        album_count = max(len(works), record["album_count"])
        records.append({
            "name": name,
            "aliases": aliases,
            "region": region,
            "image_url": record["image_url"],
            "tags": tags_out,
            "summary": f"{site['tag']}。" if album_count else None,
            "album_count": album_count or None,
            "source": key,
            "source_url": (works[0]["url"] if works else first_post.get(name, "")),
            "works": works[:400],
        })
    records.sort(key=lambda row: -(row.get("album_count") or 0))
    out_path = os.path.join(RAW, site["out"])
    tmp = out_path + ".tmp"
    json.dump(records, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, out_path)
    print(f"  近重复归并 {merged} 条；完成 {len(records)} 人"
          f"（有封面 {sum(1 for r in records if r.get('image_url'))}，"
          f"有作品 {sum(1 for r in records if r.get('works'))}）→ {site['out']}",
          flush=True)

    if site.get("studios"):
        studios = []
        for tag in tags.values():
            name = (tag.get("name") or "").strip()
            count = tag.get("count") or 0
            if count < 2 or not is_org(name) or name.casefold() in GENERIC:
                continue
            region = "taiwan" if "beautyleg" in name.casefold() else (
                "korea" if name.casefold() in KOREAN_ORGS else "china")
            studios.append({
                "name": name,
                "aliases": [],
                "region": region,
                "work_count": count,
                "source": key,
                "source_url": tag.get("link") or site["base"],
            })
        studios.sort(key=lambda row: -row["work_count"])
        out_path = os.path.join(RAW, site["studios"])
        tmp = out_path + ".tmp"
        json.dump(studios, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        os.replace(tmp, out_path)
        print(f"  机构 {len(studios)} 个 → {site['studios']}", flush=True)


def main():
    os.makedirs(RAW, exist_ok=True)
    wanted = {value.strip() for value in (os.environ.get("CN_ROUND10_SITES") or "").split(",")
              if value.strip()}
    max_pages = int(os.environ.get("CN_ROUND10_MAX_PAGES") or 0) or None
    for site in SITES:
        if wanted and site["key"] not in wanted:
            continue
        build_site(site, max_pages)


if __name__ == "__main__":
    main()
