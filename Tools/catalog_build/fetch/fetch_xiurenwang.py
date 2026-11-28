#!/usr/bin/env python3
"""第九轮：秀人网镜像站（xiurenwang.com.cn）全量写真模特档案。

用法：python3 Tools/catalog_build/fetch/fetch_xiurenwang.py
输出：Tools/catalog_build/raw/cn_profiles_web9.json

站点是 WordPress，REST API 全开（19,558 篇文章 + 2,206 个标签）。
标题里带模特名与套图编号，正文首图就是封面，正好拼出「人 + 作品 + 头像」：
- `Umeko J – NO.181 Puring Classmate [82P7V 1.06GB]`
- `[Xiuren秀人网]2023.10.27 NO.7577 徐莉芝Booty[102+1P/833MB]`
- `[微密圈]迷人的五姨太 –宫廷娘娘[40P1V-298M]`

人物名从标题解析（`–` 前段 或 `NO.xxxx` 后段），站方标签只用来交叉校验与过滤
机构/系列标签（「精选单套」「写真模特」「模特合辑」这类不是人）。
只取文字档案与作品目录，不下载图片。
"""

from __future__ import annotations

import html
import json
import os
import re
import sqlite3
import time
import unicodedata

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "cn_profiles_web9.json")
BASE = "https://www.xiurenwang.com.cn"

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"),
    "Accept-Language": "zh-CN,zh;q=0.9",
})

# 站方机构 / 系列标签：不是具体模特，标题解析时也会跳过这些名字。
ORG_TAGS = {
    "精选单套", "秀人网", "微密圈", "爱尤物(尤果网)", "爱尤物", "尤果网", "尤蜜荟",
    "语画界", "喵糖印画", "丽柜", "vmb", "LRXX", "爱蜜社", "星颜社", "美媛馆",
    "蜜桃社", "魅妍社", "尤物馆", "波萝社", "果团网", "秘密花园", "青柠映画",
    "美图馆", "推女郎", "Ugirls尤果网", "花の绘", "优星馆", "美丝社", "街拍",
    "视频", "新人", "写真模特", "模特合辑", "模特合集", "名站写真", "ROSI写真",
    "御女郎", "推女神", "青豆客", "第四印象", "异思趣向", "头条女神", "森萝财团",
    "模范学院", "糖果画报(网红馆)", "Beautylegt腿模", "风之领域", "套图",
    "性感", "汉服", "比基尼", "花漾", "嗲囡囡", "雅拉伊", "LEEHEE EXPRESS",
    "ARTGRAVIA", "尤果合輯", "尤果合集", "fantia",
}

# 全小写精确匹配的机构名（避免 LR 误伤 Lris 之类）。
ORG_LOWER = {"lr", "bno", "fantia", "artgravia"}

# 标题前段偶尔整段是机构名（`Ligui丽柜 – 日期《套名》模特`），用子串兜住。
ORG_SUBSTR = re.compile(
    r"(Ligui|丽柜|尤果网|UGirls|爱尤物|尤蜜荟|语画界|喵糖|美媛馆|美图馆|蜜桃社|"
    r"魅妍社|星颜社|爱蜜社|尤物馆|波萝社|果团网|秘密花园|青柠映画|优星馆|美丝社|"
    r"推女郎|Beautylegt|精选单套|写真模特|模特合辑|模特合集|名站写真|ROSI|"
    r"秀人网|微密圈|雅拉伊|YALAYI|LEEHEE|ARTGRAVIA|尤果合)", re.I)

# 名字里出现这些词说明是系列/题材标签，不是人。
ORG_WORD = re.compile(
    r"(写真|合辑|合集|系列|套图|图集|画报|学院|财团|印象|趣向|领域|腿模|"
    r"美图|女神馆|女郎|尤物馆|网红馆|影像|摄影|工作室|传媒)$")

# B 模式尾巴上的题材词（「浅浅Danny 美腿女神」里的「美腿女神」）。
GENERIC_TAIL = re.compile(
    r"\s*(美腿女神|美腿|女神|美臀|蜜桃臀|黑丝|白丝|丝袜|制服|旗袍|比基尼|内衣|"
    r"护士|空姐|秘书|教师|女仆|萝莉|御姐|人妻|熟女|泳装|情趣|美少女)\s*$")

BRACKET_PREFIX = re.compile(r"^\s*(?:\[[^\]]{1,40}\]|【[^】]{1,40}】)\s*")
DATE_PREFIX = re.compile(r"^\s*(?:\d{4}[.\-/年]\d{1,2}[.\-/月]\d{1,2}日?\s*)")
NO_PATTERN = re.compile(r"(?:NO|No|no)\.?\s*(\d{1,5})\b")
DASH_SPLIT = re.compile(r"\s*[–—]\s*")
NAME_ALIAS = re.compile(r"^(.{2,}?)\s*[（(]([^）)]{2,30})[）)]$")
IMAGE_RE = re.compile(
    r'<img[^>]+(?:data-src|src)="([^"]*wp-content/uploads/[^"]+?\.(?:jpg|jpeg|png|webp))"',
    re.I)
DATE_RE = re.compile(r"((?:19|20)\d{2})[.\-/年](\d{1,2})[.\-/月](\d{1,2})")
KANA = re.compile(r"[ぁ-んァ-ヶ]")
HANGUL = re.compile(r"[\uac00-\ud7af]")
CJK = re.compile(r"[\u4e00-\u9fa5]")


def fetch_json(url, tries=4):
    for attempt in range(tries):
        try:
            response = SESSION.get(url, timeout=30)
            if response.status_code == 200:
                return response.json(), response.headers
            if response.status_code == 400:
                return [], response.headers
            time.sleep(1.5 * (attempt + 1))
        except (requests.RequestException, ValueError):
            time.sleep(1.5 * (attempt + 1))
    return None, {}


def fetch_tags():
    tags = {}
    for page in range(1, 40):
        data, headers = fetch_json(
            f"{BASE}/wp-json/wp/v2/tags?per_page=100&page={page}"
            "&_fields=id,name,count")
        if not data:
            break
        for tag in data:
            tags[tag["id"]] = {"name": tag["name"], "count": tag.get("count", 0)}
        print(f"  标签第 {page} 页，累计 {len(tags)}", flush=True)
        if len(data) < 100:
            break
        time.sleep(0.3)
    return tags


def is_org_name(name):
    value = (name or "").strip()
    if not value:
        return True
    if value in ORG_TAGS:
        return True
    if value.lower() in ORG_LOWER:
        return True
    if ORG_SUBSTR.search(value):
        return True
    # 站方占位名（「美少女@」）不是人。
    if value.endswith("@") or value in {"美少女"}:
        return True
    return bool(ORG_WORD.search(value))


def clean_person_name(raw):
    """把标题前段 / 站方标签清洗成 (主名, [别名])；判不出人名返回 (None, [])。"""
    value = html.unescape(raw or "").strip()
    value = re.sub(r"\s+", " ", value).strip(" -–—|·")
    # 反复剥掉方括号栏目与日期前缀
    for _ in range(3):
        new = BRACKET_PREFIX.sub("", value)
        new = DATE_PREFIX.sub("", new)
        if new == value:
            break
        value = new.strip()
    value = refine_spaced(value)
    # 站方偶尔把整条标题当标签（「是依酱吖 – NO.082 奶牛 [23P4V-149MB]」）。
    value = re.sub(r"\s*人物$", "", value).strip()
    if not value or len(value) > 40:
        return None, []
    if re.search(r"(NO\.|No\.|VOL\.|Vol\.|\d+\s*[Pp]\b|【|】|\[|\])", value):
        return None, []
    if is_org_name(value):
        return None, []
    aliases = []
    match = NAME_ALIAS.match(value)
    if match:
        value, inner = match.group(1).strip(), match.group(2).strip()
        if inner and inner != value:
            aliases.append(inner)
    # 尾部题材词剥掉（仅在没有括号别名时）
    for _ in range(2):
        stripped = GENERIC_TAIL.sub("", value).strip()
        if stripped == value:
            break
        value = stripped
    if not value or is_org_name(value):
        return None, []
    if re.fullmatch(r"[\d\s.\-]+", value):
        return None, []
    if not (CJK.search(value) or re.search(r"[A-Za-z]{2,}", value)):
        return None, []
    return value, aliases


# 爱尤物 / 果团网 的部分标签是「套名 人名」整串（「气息 佳佳」「黑丝心跳 葛征」）。
SPACED_TAIL = re.compile(
    r"(尤物|女神|少女|旗袍|情诗|情话|御守|私房|写真|物语|物語|心尖尖)$")


def refine_spaced(value):
    """含一个空格的「套名 人名」串，切出人名；纯拉丁名（Candy Ball）不动。"""
    if " " not in value:
        return value
    parts = value.split()
    if len(parts) != 2:
        return value
    head, tail = parts
    if not CJK.search(head):
        return value
    if SPACED_TAIL.search(tail):
        return head
    # 前段是长套名（≥4 汉字）时，人名为后段。
    if len(re.findall(r"[\u4e00-\u9fa5]", head)) >= 4:
        return tail
    return value


def parse_title(title):
    """标题 → (作品编号, 人物 [(主名, 别名列表)])。"""
    text = html.unescape(re.sub(r"<[^>]+>", "", title or "")).strip()
    if not text:
        return None, []
    no = None
    match = NO_PATTERN.search(text)
    if match:
        no = int(match.group(1))

    people = []
    head = DASH_SPLIT.split(text, maxsplit=1)[0]
    if DASH_SPLIT.search(text):
        # `名字 – 套名` 模式：前段就是人名（双人合作用 & 连接）。
        for part in re.split(r"\s*[&＆]\s*", head):
            name, aliases = clean_person_name(part)
            if name:
                people.append((name, aliases))
    if not people and match:
        # `[秀人网]日期 NO.xxxx 名字[规格]` 模式：NO 之后到规格括号前。
        rest = text[match.end():]
        rest = re.split(r"[\[\(（【]", rest, maxsplit=1)[0]
        for part in re.split(r"\s*[&＆]\s*", rest):
            name, aliases = clean_person_name(part)
            if name:
                people.append((name, aliases))
    # 去重保序
    seen, unique = set(), []
    for name, aliases in people:
        if name not in seen:
            seen.add(name)
            unique.append((name, aliases))
    return no, unique


def region_of(name, aliases):
    probe = name + " " + " ".join(aliases)
    if HANGUL.search(probe):
        return "korea"
    if KANA.search(probe):
        return "japan"
    # 只有名字里没有汉字时，才可能靠拉丁/假名判断；其余归国内写真模特。
    if not CJK.search(name):
        if HANGUL.search(probe):
            return "korea"
        if KANA.search(probe):
            return "japan"
    return "china"


def cover_of(content):
    match = IMAGE_RE.search(content or "")
    return match.group(1) if match else None


MERGE_SUFFIX = re.compile(r"^[A-Za-z]{1,4}$")
CJK_ONLY = re.compile(r"^[\u4e00-\u9fa5]+$")
# 别名巧合造成的误合并（不是同一人），绝不并入。
MERGE_BLOCKLIST = {"laurelzoe", "momori", "pyoncos", "roglemin",
                   "hanako", "mikallen", "女主k"}


def normalize_name(value):
    text = unicodedata.normalize("NFKC", (value or "")).casefold()
    return re.sub(r"[\s\-_·・.。,，'\"()（）【】\[\]@]+", "", text)


def library_names():
    """读现有 catalog.sqlite 的 name/aliases → {归一化名: 主名}，供近重复归并。"""
    path = os.environ.get("LUMA_CATALOG_DB") or os.path.expanduser("~/Downloads/catalog.sqlite")
    if not os.path.exists(path):
        return {}
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = conn.execute("SELECT name, aliases FROM actresses").fetchall()
    finally:
        conn.close()
    table = {}
    alias_rows = []
    # 主名优先：同一个键既是某人的主名、又是别人的别名时（如「洛璃LoLiSAMA」
    # 被错挂到日本女优 LISA 上），以主名为准，避免新抓的数据并进错误的人。
    for name, aliases in rows:
        key = normalize_name(name)
        if key:
            table.setdefault(key, name)
        alias_rows.append((name, aliases))
    for name, aliases in alias_rows:
        try:
            values = json.loads(aliases or "[]")
        except ValueError:
            values = []
        for value in values:
            key = normalize_name(value)
            if key:
                table.setdefault(key, name)
    return table


def canonical_for(name, table):
    """新名若是「库内纯中文主名 + 1-4 位字母尾缀」，归一到库内主名。"""
    key = normalize_name(name)
    if not key or key in MERGE_BLOCKLIST:
        return None
    if key in table:
        return table[key]
    for cut in range(1, 5):
        if len(key) <= cut + 1:
            break
        suffix, prefix = key[-cut:], key[:-cut]
        if not MERGE_SUFFIX.match(suffix):
            continue
        canonical = table.get(prefix)
        if canonical and CJK_ONLY.match(canonical):
            return canonical
    return None


def build():
    os.makedirs(RAW, exist_ok=True)
    cache_dir = os.path.join(RAW, ".xw_pages")
    os.makedirs(cache_dir, exist_ok=True)
    print("拉取站方标签…", flush=True)
    tags = fetch_tags()
    print(f"标签 {len(tags)} 个", flush=True)

    people: dict[str, dict] = {}
    page = 1
    total_pages = None
    while True:
        cache_path = os.path.join(cache_dir, f"p{page:04d}.json")
        if os.path.exists(cache_path):
            data = json.load(open(cache_path, encoding="utf-8"))
            headers = {}
        else:
            data, headers = fetch_json(
                f"{BASE}/wp-json/wp/v2/posts?per_page=100&page={page}"
                "&_fields=id,title,link,tags,content")
            # 断点续抓：整页缓存，重跑不再重复下载 200MB 正文。
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
            print(f"文章共 {total_pages} 页", flush=True)
        for post in data:
            title = (post.get("title") or {}).get("rendered", "")
            no, title_names = parse_title(title)
            # 人名以站方标签为准：爱尤物 / 雅拉伊 的标题是「NO.xxx 套名 人名」，
            # 直接切标题会把套名当成名字（「气息 佳佳」「黑丝心跳 葛征」），
            # 而标签只标真人名，cosplay 角色名也不会进标签。
            post_tags = [tags[tid]["name"] for tid in post.get("tags") or []
                         if tid in tags and not is_org_name(tags[tid]["name"])]
            names = []
            for tag_name in post_tags:
                name, aliases = clean_person_name(tag_name)
                if name and not any(n == name for n, _ in names):
                    names.append((name, aliases))
            # 没有可用标签时，退回标题解析。
            if not names:
                names = title_names
            if not names:
                continue
            image = cover_of((post.get("content") or {}).get("rendered", ""))
            work_title = html.unescape(re.sub(r"<[^>]+>", "", title)).strip()
            for name, aliases in names:
                record = people.setdefault(name, {
                    "aliases": [], "works": [], "image_url": None,
                    "tag_names": set(), "region_hint": None,
                })
                for alias in aliases:
                    if alias not in record["aliases"] and alias != name:
                        record["aliases"].append(alias)
                if name in post_tags:
                    record["tag_names"].add(name)
                record["works"].append({
                    "no": no, "title": work_title[:160],
                    "url": post.get("link") or "",
                })
                if image and not record["image_url"]:
                    record["image_url"] = image
        if page % 20 == 0:
            print(f"  文章第 {page}/{total_pages or '?'} 页，累计人物 {len(people)}",
                  flush=True)
        if total_pages and page >= total_pages:
            break
        if len(data) < 100:
            break
        page += 1
        time.sleep(0.15)

    # 库内已有「封疆疆」时，站方的「封疆疆v」「咬一口兔娘ovo」是同一人，
    # 归一到库内主名再落库，避免重复条目（合并逻辑按名字精确建 key）。
    table = library_names()
    merged_into = 0
    canonical_people: dict[str, dict] = {}
    for name, record in people.items():
        target_name = canonical_for(name, table) or name
        target = canonical_people.setdefault(target_name, {
            "aliases": [], "works": [], "image_url": None})
        if target_name != name:
            merged_into += 1
            if name not in target["aliases"]:
                target["aliases"].append(name)
        for alias in record["aliases"]:
            if alias != target_name and alias not in target["aliases"]:
                target["aliases"].append(alias)
        target["works"].extend(record["works"])
        if record["image_url"] and not target["image_url"]:
            target["image_url"] = record["image_url"]
    if merged_into:
        print(f"近重复归并 {merged_into} 条（如 封疆疆v → 封疆疆）", flush=True)

    records = []
    for name, record in canonical_people.items():
        aliases = record["aliases"]
        works, seen_work = [], set()
        for work in record["works"]:
            key = work.get("url") or work.get("title")
            if key in seen_work:
                continue
            seen_work.add(key)
            works.append(work)
        tags_out = ["写真模特"]
        if not CJK.search(name) and not KANA.search(name) and not HANGUL.search(name):
            tags_out.append("网红")
        records.append({
            "name": name,
            "aliases": [alias for alias in aliases if alias != name],
            "region": region_of(name, aliases),
            "image_url": record["image_url"],
            "tags": tags_out,
            "summary": f"写真模特，站内收录 {len(works)} 套图集。",
            "album_count": len(works),
            "source": "xiurenwang",
            "source_url": works[0]["url"] if works else "",
            "works": works[:200],
        })
    records.sort(key=lambda row: -len(row["works"]))
    tmp = OUT + ".tmp"
    json.dump(records, open(tmp, "w", encoding="utf-8"), ensure_ascii=False,
              indent=1)
    os.replace(tmp, OUT)
    with_cover = sum(1 for row in records if row.get("image_url"))
    with_works = sum(1 for row in records if row.get("works"))
    print(f"完成：人物 {len(records)} 条（有封面 {with_cover}，有作品 {with_works}）→ {OUT}")


if __name__ == "__main__":
    build()
