#!/usr/bin/env python3
"""一次性修正 cn_profiles_xsnvshen.json 的 region 误判。

背景（2026-11-25）：xsnvshen 资料页「出生」字段写法是「中国 台湾 台北市」带空格，
fetch_xsnvshen.py 的 REGION_MAP 无空格前缀匹配全部失效，都掉进 startswith("中国")
→ china；海外出生地（美国/泰国/马来西亚等）也 fallback 到 china。

修正策略：只动 region=china 的记录，用已剥离「中国」前缀的 birthplace 重新判定；
不匹配任何规则的（中国省市、城市、脏数据、澳门）保持 china 不变。
备份原文件为 cn_profiles_xsnvshen.json.bak。

用法：python3 Tools/catalog_build/fix_xsnvshen_region.py
"""

from __future__ import annotations

import json
import os
import shutil
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
TARGET = os.path.join(RAW, "cn_profiles_xsnvshen.json")

# 顺序敏感：中国台湾/中国香港/中国台北必须排在通用规则前。
PREFIX_RULES = (
    # 台湾
    ("中国台湾", "taiwan"), ("中国台北", "taiwan"),
    ("台湾", "taiwan"), ("台北", "taiwan"), ("新北", "taiwan"),
    # 香港
    ("中国香港", "hongkong"), ("香港", "hongkong"),
    # 日本（海外出生的日系地名）
    ("东京都", "japan"), ("大阪府", "japan"), ("熊本县", "japan"),
    # 韩国
    ("首尔", "korea"),
    # 海外国名 / 海外城市 → western
    ("美国", "western"), ("泰国", "western"), ("马来西亚", "western"),
    ("俄罗斯", "western"), ("越南", "western"), ("澳大利亚", "western"),
    ("加拿大", "western"), ("巴西", "western"), ("英国", "western"),
    ("新加坡", "western"), ("墨西哥", "western"), ("菲律宾", "western"),
    ("菲利宾", "western"), ("德国", "western"), ("乌克兰", "western"),
    ("哥伦比亚", "western"), ("以色列", "western"), ("海外", "western"),
    ("法国", "western"), ("意大利", "western"), ("西班牙", "western"),
    ("丹麦", "western"), ("南非", "western"), ("荷兰", "western"),
    ("波兰", "western"), ("印度", "western"), ("印度尼西亚", "western"),
    ("塞尔维亚", "western"), ("挪威", "western"), ("委内瑞拉", "western"),
    ("瑞典", "western"), ("古巴", "western"), ("土耳其", "western"),
    ("奥地利", "western"), ("新西兰", "western"), ("波多黎各", "western"),
    ("乌兹别克斯坦", "western"), ("希腊", "western"), ("捷克", "western"),
    ("智利", "western"), ("比利时", "western"), ("瑞士", "western"),
    ("白俄罗斯", "western"), ("秘鲁", "western"), ("缅甸", "western"),
    ("伊朗", "western"), ("克罗地亚", "western"), ("匈牙利", "western"),
    ("哥斯达黎加", "western"), ("斯洛伐克", "western"), ("柬埔寨", "western"),
    ("爱尔兰", "western"), ("罗马尼亚", "western"), ("老挝", "western"),
    ("葡萄牙", "western"), ("阿根廷", "western"), ("黎巴嫩", "western"),
    ("保加利亚", "western"), ("多米尼加", "western"), ("摩洛哥", "western"),
    ("格鲁吉亚", "western"), ("波斯尼亚", "western"), ("蒙古", "western"),
    ("吉隆坡", "western"), ("莎阿南", "western"),
)


def new_region(birthplace):
    text = (birthplace or "").strip()
    if not text:
        return None
    for prefix, region in PREFIX_RULES:
        if text.startswith(prefix):
            return region
    # 「泰安市->日本」「->日本」这类迁居写法
    if "->日本" in text:
        return "japan"
    return None  # 不匹配 → 保持原值


def main():
    data = json.load(open(TARGET, encoding="utf-8"))
    backup = TARGET + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(TARGET, backup)
        print(f"已备份 → {backup}")

    changed = Counter()
    untouched = Counter()
    for record in data:
        if record.get("region") != "china":
            continue
        region = new_region(record.get("birthplace"))
        if region and region != record.get("region"):
            changed[region] += 1
            record["region"] = region
        else:
            untouched[record.get("birthplace", "").split(" ")[0] if record.get("birthplace") else "(空)"] += 1

    tmp = TARGET + ".tmp"
    json.dump(data, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, TARGET)

    final = Counter(r.get("region") for r in data)
    print(f"修正分配：{dict(changed)}")
    print(f"保持 china：{sum(untouched.values())} 条（首词 {len(untouched)} 种，含中国省市/城市/脏数据/澳门）")
    print(f"修正后 region 分布：{dict(final)}")


if __name__ == "__main__":
    main()
