#!/usr/bin/env python3
"""把 Apple Vision 分类器的原始结果按 AppleVisionTagMapper 的规则映射成中文标签，
与 SigLIP 的分数合并，生成一份用于评测「P2.5 第二信号」的 predictions 文件。

规则表是 Sources/Luma/Services/Media/AppleVisionTagMapper.swift 的镜像；
新增或修改映射时两处都要改，否则离线评测会与 App 行为不一致。

做法：映射得到的标签把分数抬到「阈值 + 0.001」，这样 goldset_eval 的阈值判断
一定会保留它；其余标签仍用原始余弦分数。

用法：
  # 总是合入（线上 P2.5 的做法）
  python3 Tools/vision_bench/p25_union.py predictions.json tags.json union.json

  # 门控 A/B：只有 SigLIP 标签数 < 2 时才补 Apple 信号
  python3 Tools/vision_bench/p25_union.py predictions.json tags.json union_gate2.json --gate-below 2
"""

import argparse
import json

# 与 AppleVisionTagMapper.swift 保持一致（key 为 Apple identifier 的小写形式）
RULES = {
    # 人物 / 关系
    "people": ("人物", 0.30), "adult": ("人物", 0.30), "crowd": ("人物", 0.35),
    "child": ("儿童", 0.30), "teen": ("儿童", 0.35), "baby": ("婴儿", 0.30),
    # 文档 / 截图
    "screenshot": ("截图", 0.35), "document": ("文档", 0.35),
    "printed_page": ("文档", 0.40), "handwriting": ("文档", 0.40),
    "receipt": ("文档", 0.40), "sign": ("文档", 0.50),
    # 场景
    "sky": ("天空", 0.30), "blue_sky": ("天空", 0.30), "cloudy": ("云朵", 0.40),
    "ocean": ("海边", 0.40), "beach": ("海边", 0.40), "seashore": ("海边", 0.40),
    "lake": ("湖泊", 0.45), "hill": ("山脉", 0.45), "mountain": ("山脉", 0.40),
    "forest": ("森林", 0.35), "foliage": ("树", 0.35), "tree": ("树", 0.40),
    "branch": ("树", 0.45), "grass": ("草地", 0.40), "flower": ("花", 0.40),
    "blossom": ("花", 0.40), "waterfall": ("瀑布", 0.50), "desert": ("沙漠", 0.50),
    "library": ("图书馆", 0.40),
    # 食物 / 物体 / 交通
    "food": ("美食", 0.45), "plate": ("美食", 0.55), "bowl": ("美食", 0.55),
    "restaurant": ("美食", 0.50), "automobile": ("汽车", 0.35), "car": ("汽车", 0.35),
    "vehicle": ("汽车", 0.45), "conveyance": ("汽车", 0.50), "bicycle": ("自行车", 0.40),
    "building": ("建筑", 0.40), "skyscraper": ("建筑", 0.40), "street": ("街道", 0.40),
    "road": ("街道", 0.45), "cityscape": ("城市", 0.40), "night_sky": ("夜景", 0.35),
    "sunset_sunrise": ("日落", 0.35), "snow": ("雪景", 0.40), "frozen": ("雪景", 0.45),
    # 事件
    "wedding": ("婚礼现场", 0.40), "ceremony": ("婚礼现场", 0.45),
    "bride": ("婚纱", 0.40), "gown": ("婚纱", 0.45), "wedding_dress": ("婚纱", 0.40),
    "bouquet": ("花束", 0.40), "concert": ("演唱会现场", 0.40),
    "performance": ("演唱会现场", 0.45),
    # 服饰 / 随身物
    "handbag": ("包包", 0.35), "purse": ("包包", 0.35), "luggage": ("包包", 0.45),
    "backpack": ("包包", 0.45), "shoes": ("鞋子", 0.40), "sneaker": ("鞋子", 0.40),
    "footwear": ("鞋子", 0.45), "jacket": ("衣服", 0.40), "hoodie": ("衣服", 0.40),
    "suit": ("衣服", 0.45), "jewelry": ("珠宝", 0.40), "balloon": ("气球", 0.40),
    "flag": ("旗帜", 0.40), "bottle": ("瓶子", 0.40), "drinking_glass": ("杯子", 0.40),
    "book": ("书本", 0.40), "computer": ("电脑", 0.40),
    "computer_monitor": ("电脑", 0.40), "toy": ("玩具", 0.40),
    # 动物
    "cat": ("猫", 0.40), "adult_cat": ("猫", 0.40), "feline": ("猫", 0.45),
    "dog": ("狗", 0.40),
}

LABEL_LIMIT = 12


def siglip_label_count(scores, tags, limit=LABEL_LIMIT):
    """SigLIP 单独能给出的标签数（阈值 + top-12，和 App 的限额一致）。"""
    hits = [tag for tag in tags if scores.get(tag["id"], -1.0) >= float(tag.get("threshold") or 0.085)]
    return min(len(hits), limit)


def main():
    parser = argparse.ArgumentParser(description="SigLIP + Apple 映射标签合并")
    parser.add_argument("pred")
    parser.add_argument("tags")
    parser.add_argument("out")
    parser.add_argument("--gate-below", type=int, default=None,
                        help="仅当 SigLIP 标签数小于该值才补 Apple（不填 = 总是补）")
    parser.add_argument("--label-limit", type=int, default=LABEL_LIMIT)
    args = parser.parse_args()

    tags = json.load(open(args.tags, encoding="utf-8"))["tags"]
    title_to_tag = {tag["title"]: tag for tag in tags}
    source = json.load(open(args.pred, encoding="utf-8"))

    injected = 0
    gated_out = 0
    mapped_hits = {}
    items = []
    for item in source["items"]:
        scores = dict(item.get("scores") or {})
        count = siglip_label_count(scores, tags, args.label_limit)
        if args.gate_below is not None and count >= args.gate_below:
            gated_out += 1
            items.append({"id": item["id"], "path": item.get("path", ""), "scores": scores,
                          "siglipCount": count, "appleMapped": []})
            continue
        added = []
        for entry in item.get("apple") or []:
            key = str(entry.get("label", "")).lower()
            rule = RULES.get(key)
            if not rule:
                continue
            title, minimum = rule
            if float(entry.get("confidence", 0)) < minimum:
                continue
            tag = title_to_tag.get(title)
            if not tag or title in added:
                continue
            added.append(title)
            floor = float(tag.get("threshold") or 0.085) + 0.001
            if scores.get(tag["id"], -1.0) < floor:
                scores[tag["id"]] = floor
                injected += 1
            mapped_hits[title] = mapped_hits.get(title, 0) + 1
        items.append({"id": item["id"], "path": item.get("path", ""), "scores": scores,
                      "siglipCount": count, "appleMapped": added})

    gate_note = "" if args.gate_below is None else f"；门控 SigLIP<{args.gate_below}，跳过 {gated_out} 张"
    output = {
        "generatedAt": source.get("generatedAt"),
        "source": args.pred,
        "note": f"SigLIP 分数 + Apple 映射标签（抬到阈值+0.001），用于 P2.5 离线评测{gate_note}",
        "gateBelow": args.gate_below,
        "items": items,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(output, handle, ensure_ascii=False)
    top = sorted(mapped_hits.items(), key=lambda pair: -pair[1])[:12]
    print(f"注入 {injected} 个标签分数，门控跳过 {gated_out} 张 → {args.out}")
    print("Apple 映射命中（张）：", ", ".join(f"{k}={v}" for k, v in top))


if __name__ == "__main__":
    main()
