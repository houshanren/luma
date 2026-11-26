#!/usr/bin/env python3
"""抓取头部厂牌官网的品牌图/图标 URL，写入 raw/studio_logos.json。

只保存 URL，不下载图片；403/超时的站点跳过，不编造。
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import time
from urllib.parse import urljoin

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT = os.path.join(RAW, "studio_logos.json")
PROXIES = {"http": "http://127.0.0.1:8118", "https": "http://127.0.0.1:8118"}


def load_sites():
    spec = importlib.util.spec_from_file_location(
        "build_catalog_db", os.path.join(ROOT, "Tools", "catalog_build", "build_catalog_db.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.STUDIO_WEBSITES


def meta_image(text, base):
    for pattern in (
        r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)',
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:image["\']',
        r'<link[^>]+rel=["\'][^"\']*apple-touch-icon[^"\']*["\'][^>]+href=["\']([^"\']+)',
        r'<link[^>]+rel=["\'][^"\']*icon[^"\']*["\'][^>]+href=["\']([^"\']+)',
    ):
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return urljoin(base, match.group(1))
    return None


def main():
    sites = load_sites()
    result = {}
    session = requests.Session()
    session.proxies.update(PROXIES)
    session.headers.update({"User-Agent": "Mozilla/5.0"})
    for index, (name, url) in enumerate(sites.items(), 1):
        try:
            response = session.get(url, timeout=20)
            if response.status_code != 200:
                print(f"  {index}/{len(sites)} {name} {response.status_code}")
                continue
            image = meta_image(response.text, response.url)
            if image:
                result[name] = {"website": url, "logo_url": image}
                print(f"  {index}/{len(sites)} {name} OK")
            else:
                print(f"  {index}/{len(sites)} {name} 无品牌图")
        except requests.RequestException:
            print(f"  {index}/{len(sites)} {name} 请求失败")
        time.sleep(0.4)
    json.dump(result, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"完成：{len(result)}/{len(sites)} → {OUT}")


if __name__ == "__main__":
    main()
