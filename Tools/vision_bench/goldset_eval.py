#!/usr/bin/env python3
"""金标集评测 / 阈值校准 / A-B 对比。

配合：
  Tools/vision_bench/goldset_sample.swift   生成 1,200 张候选 goldset.json
  Tools/vision_bench/vision_predict.swift   对 goldset 跑 249 标签分数

用法：
  python3 Tools/vision_bench/goldset_eval.py summary goldset.json
  python3 Tools/vision_bench/goldset_eval.py merge goldset.json labels.json --out goldset_labeled.json
  python3 Tools/vision_bench/goldset_eval.py eval goldset.json predictions.json \
      [--tags tags.json] [--thresholds thresholds.json] [--out report.md] [--bootstrap 1000]
  python3 Tools/vision_bench/goldset_eval.py calibrate goldset.json predictions.json \
      [--tags tags.json] [--out thresholds.json] [--min-pos 5] [--min-precision 0.85]
  python3 Tools/vision_bench/goldset_eval.py compare goldset.json predA.json predB.json \
      [--tags tags.json] [--thresholds thresholds.json] [--bootstrap 1000]

注意：calibrate 是在同一份数据上选阈值，属于样本内结果；正式结论要用独立 test 集复核。
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


# ---------- 数据 ----------

def load_json(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_tags(path: str):
    data = load_json(path)
    tags = data.get("tags", [])
    by_id = {tag["id"]: tag for tag in tags}
    title_to_id = {tag["title"]: tag["id"] for tag in tags}
    return data, tags, by_id, title_to_id


def normalize_labels(labels, title_to_id):
    result = set()
    for label in labels or []:
        result.add(title_to_id.get(label, label))
    return result


def load_gold(path: str, title_to_id):
    data = load_json(path)
    items = []
    for item in data.get("items", []):
        items.append({
            "id": item["id"],
            "path": item.get("path", ""),
            "labels": normalize_labels(item.get("labels"), title_to_id),
            "reviewed": bool(item.get("reviewed")),
            "slice": item.get("slice") or {},
            "event": item.get("event"),
        })
    return data, items


def load_predictions(path: str):
    data = load_json(path)
    result = {}
    for item in data.get("items", []):
        result[item["id"]] = {
            "scores": {key: float(value) for key, value in (item.get("scores") or {}).items()},
            "top": item.get("top") or [],
            "path": item.get("path", ""),
        }
    return data, result


def thresholds_from(tags, override_path=None, default=None):
    values = {tag["id"]: float(tag.get("threshold") or default or 0.085) for tag in tags}
    if override_path:
        data = load_json(override_path)
        mapping = data.get("thresholds", data)
        for key, value in mapping.items():
            if isinstance(value, (int, float)):
                values[key] = float(value)
    return values


# ---------- 指标 ----------

def reviewed_items(items):
    """参与评测的样本：有标签，或已人工确认「无合适标签」（空负样本）。"""
    return [item for item in items if item["labels"] or item.get("reviewed")]


def item_counts(gold_labels, scores, thresholds):
    predicted = {tag for tag, threshold in thresholds.items() if scores.get(tag, -1.0) >= threshold}
    tp = len(gold_labels & predicted)
    fp = len(predicted - gold_labels)
    fn = len(gold_labels - predicted)
    return tp, fp, fn, predicted


def prf(tp, fp, fn):
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def summarize(items, predictions, thresholds):
    per_item = []
    for item in items:
        pred = predictions.get(item["id"], {"scores": {}})
        tp, fp, fn, predicted = item_counts(item["labels"], pred["scores"], thresholds)
        per_item.append({
            "id": item["id"],
            "gold": item["labels"],
            "pred": predicted,
            "tp": tp, "fp": fp, "fn": fn,
            "slice": item["slice"],
        })
    micro_tp = sum(row["tp"] for row in per_item)
    micro_fp = sum(row["fp"] for row in per_item)
    micro_fn = sum(row["fn"] for row in per_item)
    micro = prf(micro_tp, micro_fp, micro_fn)

    per_tag = []
    for tag, threshold in thresholds.items():
        tp = sum(1 for row in per_item if tag in row["gold"] and tag in row["pred"])
        fp = sum(1 for row in per_item if tag in row["pred"] and tag not in row["gold"])
        fn = sum(1 for row in per_item if tag in row["gold"] and tag not in row["pred"])
        support = tp + fn
        if support == 0 and fp == 0:
            continue
        p, r, f = prf(tp, fp, fn)
        per_tag.append({
            "id": tag, "threshold": threshold, "support": support,
            "tp": tp, "fp": fp, "fn": fn,
            "precision": p, "recall": r, "f1": f,
        })
    with_support = [row for row in per_tag if row["support"] > 0]
    macro = (
        statistics.mean(row["precision"] for row in with_support) if with_support else 0.0,
        statistics.mean(row["recall"] for row in with_support) if with_support else 0.0,
        statistics.mean(row["f1"] for row in with_support) if with_support else 0.0,
    )

    slices = defaultdict(lambda: [0, 0, 0, 0])
    for row in per_item:
        for key, value in (row["slice"] or {}).items():
            label = f"{key}={value}"
            slices[label][0] += row["tp"]
            slices[label][1] += row["fp"]
            slices[label][2] += row["fn"]
            slices[label][3] += 1
    slice_rows = []
    for label, (tp, fp, fn, count) in sorted(slices.items()):
        p, r, f = prf(tp, fp, fn)
        slice_rows.append({"slice": label, "items": count, "precision": p, "recall": r, "f1": f})

    return {
        "per_item": per_item,
        "per_tag": sorted(per_tag, key=lambda row: (-row["support"], -row["f1"], row["id"])),
        "micro": {"tp": micro_tp, "fp": micro_fp, "fn": micro_fn,
                  "precision": micro[0], "recall": micro[1], "f1": micro[2]},
        "macro": {"precision": macro[0], "recall": macro[1], "f1": macro[2]},
        "slices": slice_rows,
    }


def bootstrap_ci(per_item, iterations=1000, seed=20261128):
    if not per_item:
        return (0.0, 0.0, 0.0)
    rng = random.Random(seed)
    values = []
    n = len(per_item)
    for _ in range(iterations):
        sample = [per_item[rng.randrange(n)] for _ in range(n)]
        tp = sum(row["tp"] for row in sample)
        fp = sum(row["fp"] for row in sample)
        fn = sum(row["fn"] for row in sample)
        values.append(prf(tp, fp, fn)[2])
    values.sort()
    return (values[int(0.025 * len(values))], values[int(0.5 * len(values))],
            values[min(len(values) - 1, int(0.975 * len(values)))])


# ---------- 报告 ----------

def fmt(value):
    return f"{value:.3f}"


def write_report(path, gold_path, result, tags_by_id, ci, notes=None):
    micro = result["micro"]
    macro = result["macro"]
    lines = []
    lines.append("# 金标集评测报告\n")
    lines.append(f"- goldset：`{gold_path}`")
    lines.append(f"- 图片数：{len(result['per_item'])}")
    lines.append(f"- 有正样本标签：{len([r for r in result['per_tag'] if r['support'] > 0])}")
    lines.append(f"- micro P/R/F1：{fmt(micro['precision'])} / {fmt(micro['recall'])} / **{fmt(micro['f1'])}**")
    lines.append(f"- micro F1 95% CI（bootstrap）：{fmt(ci[0])} – {fmt(ci[2])}（中位 {fmt(ci[1])}）")
    lines.append(f"- macro P/R/F1：{fmt(macro['precision'])} / {fmt(macro['recall'])} / {fmt(macro['f1'])}")
    if notes:
        lines.append(f"- 说明：{notes}")
    lines.append("\n## 切片\n")
    lines.append("| 切片 | 图片数 | P | R | F1 |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for row in result["slices"]:
        lines.append(f"| {row['slice']} | {row['items']} | {fmt(row['precision'])} | {fmt(row['recall'])} | {fmt(row['f1'])} |")
    lines.append("\n## 标签（按支持数）\n")
    lines.append("| 标签 | 阈值 | 支持 | TP | FP | FN | P | R | F1 |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in result["per_tag"]:
        title = tags_by_id.get(row["id"], {}).get("title", row["id"])
        lines.append(f"| {title} | {row['threshold']:.3f} | {row['support']} | {row['tp']} | {row['fp']} | {row['fn']} | "
                     f"{fmt(row['precision'])} | {fmt(row['recall'])} | {fmt(row['f1'])} |")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def write_report_csv(path, result, tags_by_id):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["id", "title", "threshold", "support", "tp", "fp", "fn", "precision", "recall", "f1"])
        for row in result["per_tag"]:
            writer.writerow([row["id"], tags_by_id.get(row["id"], {}).get("title", row["id"]),
                             f"{row['threshold']:.3f}", row["support"], row["tp"], row["fp"], row["fn"],
                             f"{row['precision']:.4f}", f"{row['recall']:.4f}", f"{row['f1']:.4f}"])


# ---------- 命令 ----------

def command_summary(args):
    tags_data, tags, by_id, title_to_id = load_tags(args.tags)
    data, items = load_gold(args.gold, title_to_id)
    labelled = [item for item in items if item["labels"]]
    all_labels = [label for item in labelled for label in item["labels"]]
    support = defaultdict(int)
    for label in all_labels:
        support[label] += 1
    print(f"goldset items={len(items)} labelled={len(labelled)} unique_labels={len(support)}")
    print(f"tags.json={len(tags)} ids")
    missing = sorted(label for label in support if label not in by_id)
    if missing:
        print(f"WARN 不在 tags.json 里的标签 {len(missing)} 个：{', '.join(missing[:10])}")
    slices = defaultdict(int)
    for item in items:
        for key in (item["slice"] or {}):
            slices[key] += 1
    print(f"slices={dict(sorted(slices.items()))}")
    if len(items) < 1200:
        print(f"WARN 目标 1,200 张，当前 {len(items)} 张")
    if len(labelled) < len(items):
        print(f"WARN 还有 {len(items) - len(labelled)} 张未标注")
    top = sorted(support.items(), key=lambda pair: (-pair[1], pair[0]))[:20]
    print("top labels:", ", ".join(f"{by_id.get(k, {}).get('title', k)}={v}" for k, v in top))


def command_eval(args):
    tags_data, tags, by_id, title_to_id = load_tags(args.tags)
    _, items = load_gold(args.gold, title_to_id)
    _, predictions = load_predictions(args.pred)
    labelled = reviewed_items(items)
    if not labelled:
        print("FAIL goldset 里没有任何 labels；请先人工标注。")
        sys.exit(2)
    thresholds = thresholds_from(tags, args.thresholds, tags_data.get("defaultThreshold"))
    result = summarize(labelled, predictions, thresholds)
    ci = bootstrap_ci(result["per_item"], iterations=args.bootstrap)
    print(f"items={len(labelled)} micro P/R/F1="
          f"{fmt(result['micro']['precision'])}/{fmt(result['micro']['recall'])}/{fmt(result['micro']['f1'])} "
          f"CI={fmt(ci[0])}-{fmt(ci[2])}")
    print(f"macro P/R/F1={fmt(result['macro']['precision'])}/{fmt(result['macro']['recall'])}/{fmt(result['macro']['f1'])}")
    if args.out:
        write_report(args.out, args.gold, result, by_id, ci)
        print(f"wrote {args.out}")
    if args.csv:
        write_report_csv(args.csv, result, by_id)
        print(f"wrote {args.csv}")


def command_calibrate(args):
    tags_data, tags, by_id, title_to_id = load_tags(args.tags)
    _, items = load_gold(args.gold, title_to_id)
    _, predictions = load_predictions(args.pred)
    labelled = reviewed_items(items)
    if not labelled:
        print("FAIL goldset 里没有任何 labels；请先人工标注。")
        sys.exit(2)
    default = float(tags_data.get("defaultThreshold") or 0.085)
    output = {
        "version": 1,
        "createdAt": datetime.now().astimezone().isoformat(),
        "goldset": args.gold,
        "note": "样本内校准；正式发布前必须用独立 test 集复核。",
        "defaultThreshold": default,
        "thresholds": {},
        "details": {},
    }
    rows = []
    insufficient = 0
    for tag in tags:
        gold = [item for item in labelled if tag["id"] in item["labels"]]
        negatives = [item for item in labelled if tag["id"] not in item["labels"]]
        old = float(tag.get("threshold") or default)
        if not gold:
            # 金标集里没有这个标签：把阈值抬到已见负样本之上，先压住误报；
            # 这不代表标签被废弃，只代表这份数据无法评估它的召回。
            max_negative = max(
                (predictions.get(item["id"], {}).get("scores", {}).get(tag["id"], -1.0)
                 for item in negatives),
                default=-1.0
            )
            new = min(0.18, max(old, max_negative + 0.005)) if max_negative >= 0 else old
            new = round(new, 3)
            output["thresholds"][tag["id"]] = new
            output["details"][tag["id"]] = {
                "title": tag["title"], "old": old, "new": new,
                "support": 0, "maxNegative": round(max_negative, 4),
                "reason": "no-positive"
            }
            continue
        if len(gold) < args.min_pos:
            output["thresholds"][tag["id"]] = old
            output["details"][tag["id"]] = {
                "title": tag["title"], "old": old, "new": old,
                "support": len(gold), "reason": "insufficient"
            }
            insufficient += 1
            continue

        best = None
        step = 0.002
        threshold = 0.05
        while threshold <= 0.1801:
            tp = sum(1 for item in gold
                     if predictions.get(item["id"], {}).get("scores", {}).get(tag["id"], -1.0) >= threshold)
            fp = sum(1 for item in negatives
                     if predictions.get(item["id"], {}).get("scores", {}).get(tag["id"], -1.0) >= threshold)
            fn = len(gold) - tp
            precision, recall, f1 = prf(tp, fp, fn)
            if best is None or (f1, threshold) > (best["f1"], best["threshold"]):
                best = {"threshold": threshold, "precision": precision, "recall": recall,
                        "f1": f1, "tp": tp, "fp": fp, "fn": fn}
            threshold = round(threshold + step, 4)

        # 先找满足精度下限的最高 F1；没有就退回全局最高 F1。
        candidates = []
        threshold = 0.05
        while threshold <= 0.1801:
            tp = sum(1 for item in gold
                     if predictions.get(item["id"], {}).get("scores", {}).get(tag["id"], -1.0) >= threshold)
            fp = sum(1 for item in negatives
                     if predictions.get(item["id"], {}).get("scores", {}).get(tag["id"], -1.0) >= threshold)
            fn = len(gold) - tp
            precision, recall, f1 = prf(tp, fp, fn)
            if precision >= args.min_precision and recall > 0:
                candidates.append({"threshold": threshold, "precision": precision, "recall": recall,
                                   "f1": f1, "tp": tp, "fp": fp, "fn": fn})
            threshold = round(threshold + step, 4)
        chosen = max(candidates, key=lambda row: (row["f1"], row["threshold"])) if candidates else best
        if chosen["f1"] <= 0:
            new = old
            reason = "no-signal"
        else:
            new = round(chosen["threshold"], 3)
            reason = "precision-floor" if candidates else "best-f1"
        output["thresholds"][tag["id"]] = new
        output["details"][tag["id"]] = {
            "title": tag["title"], "old": old, "new": new,
            "support": len(gold), "precision": chosen["precision"],
            "recall": chosen["recall"], "f1": chosen["f1"],
            "reason": reason
        }
        rows.append((tag, old, new, len(gold), chosen))

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(output, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"wrote {args.out} tags={len(output['thresholds'])}")
    changed = sum(1 for tag in tags
                  if abs(output["thresholds"][tag["id"]] - float(tag.get("threshold") or default)) >= 0.001)
    print(f"changed={changed} insufficient={insufficient}")
    for tag, old, new, support, chosen in sorted(rows, key=lambda row: -row[3])[:15]:
        print(f"  {tag['title']}: {old:.3f} -> {new:.3f} support={support} "
              f"P={chosen['precision']:.3f} R={chosen['recall']:.3f} F1={chosen['f1']:.3f}")


def command_compare(args):
    tags_data, tags, by_id, title_to_id = load_tags(args.tags)
    _, items = load_gold(args.gold, title_to_id)
    labelled = [item for item in items if item["labels"]]
    _, pred_a = load_predictions(args.pred_a)
    _, pred_b = load_predictions(args.pred_b)
    thresholds = thresholds_from(tags, args.thresholds, tags_data.get("defaultThreshold"))

    def build(predictions):
        rows = []
        for item in labelled:
            tp, fp, fn, predicted = item_counts(item["labels"],
                                                predictions.get(item["id"], {}).get("scores", {}),
                                                thresholds)
            rows.append({"tp": tp, "fp": fp, "fn": fn, "pred": predicted, "gold": item["labels"],
                         "id": item["id"]})
        return rows

    rows_a = build(pred_a)
    rows_b = build(pred_b)
    f1_a = prf(sum(r["tp"] for r in rows_a), sum(r["fp"] for r in rows_a), sum(r["fn"] for r in rows_a))[2]
    f1_b = prf(sum(r["tp"] for r in rows_b), sum(r["fp"] for r in rows_b), sum(r["fn"] for r in rows_b))[2]
    exact_a = sum(1 for r in rows_a if r["pred"] == r["gold"]) / max(1, len(rows_a))
    exact_b = sum(1 for r in rows_b if r["pred"] == r["gold"]) / max(1, len(rows_b))

    rng = random.Random(20261128)
    deltas = []
    n = len(rows_a)
    for _ in range(args.bootstrap):
        indices = [rng.randrange(n) for _ in range(n)]
        ta = [rows_a[i] for i in indices]
        tb = [rows_b[i] for i in indices]
        fa = prf(sum(r["tp"] for r in ta), sum(r["fp"] for r in ta), sum(r["fn"] for r in ta))[2]
        fb = prf(sum(r["tp"] for r in tb), sum(r["fp"] for r in tb), sum(r["fn"] for r in tb))[2]
        deltas.append(fb - fa)
    deltas.sort()
    low = deltas[int(0.025 * len(deltas))]
    high = deltas[min(len(deltas) - 1, int(0.975 * len(deltas)))]
    print(f"A micro F1={f1_a:.3f} exact={exact_a:.3f}")
    print(f"B micro F1={f1_b:.3f} exact={exact_b:.3f}")
    print(f"B-A delta={f1_b - f1_a:+.3f}  95% CI={low:+.3f} – {high:+.3f} (bootstrap {args.bootstrap})")
    if low > 0:
        print("结论：B 在 95% 置信区间内稳定优于 A。")
    elif high < 0:
        print("结论：B 在 95% 置信区间内稳定劣于 A。")
    else:
        print("结论：差异不显著，不能仅凭这份数据换模型。")


def command_merge(args):
    """把标注页导出的 labels.json 合并回 goldset，产出可直接评测的金标集。"""
    tags_data, tags, by_id, title_to_id = load_tags(args.tags)
    gold = load_json(args.gold)
    sheet = load_json(args.labels)
    sheet_by_id = {item["id"]: item for item in sheet.get("items", [])}
    done = empty = 0
    unknown = defaultdict(int)
    output_items = []
    for item in gold.get("items", []):
        row = dict(item)
        picked = sheet_by_id.get(item["id"])
        row["labels"] = []
        row["reviewed"] = False
        if picked and picked.get("done"):
            done += 1
            labels = [str(label).strip() for label in (picked.get("labels") or []) if str(label).strip()]
            for label in labels:
                if label not in title_to_id:
                    unknown[label] += 1
            row["labels"] = labels
            row["reviewed"] = True
            if not labels:
                empty += 1
        output_items.append(row)

    result = {
        "version": 1,
        "createdAt": datetime.now().astimezone().isoformat(),
        "source": str(args.gold),
        "labelsSource": str(args.labels),
        "mode": sheet.get("mode", "assisted"),
        "count": len(output_items),
        "reviewed": done,
        "items": output_items,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"merged reviewed={done} empty={empty} total={len(output_items)} -> {args.out}")
    if unknown:
        top = sorted(unknown.items(), key=lambda pair: -pair[1])
        print(f"WARN 有 {len(unknown)} 个标签不在 tags.json 里（评测时按未命中计）：")
        print("  " + ", ".join(f"{label}×{count}" for label, count in top[:12]))
    if sheet.get("mode") == "blind":
        edited = sum(1 for item in sheet.get("items", []) if item.get("editedAfterReveal"))
        if edited:
            print(f"注意 有 {edited} 张在看过预测之后又改过标签，召回可能偏高。")


def main():
    parser = argparse.ArgumentParser(description="金标集评测 / 阈值校准 / A-B 对比")
    sub = parser.add_subparsers(dest="command", required=True)

    summary = sub.add_parser("summary")
    summary.add_argument("gold")
    summary.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    summary.set_defaults(func=command_summary)

    merge = sub.add_parser("merge")
    merge.add_argument("gold")
    merge.add_argument("labels")
    merge.add_argument("--out", required=True)
    merge.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    merge.set_defaults(func=command_merge)

    evaluate = sub.add_parser("eval")
    evaluate.add_argument("gold")
    evaluate.add_argument("pred")
    evaluate.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    evaluate.add_argument("--thresholds", default=None)
    evaluate.add_argument("--out", default=None)
    evaluate.add_argument("--csv", default=None)
    evaluate.add_argument("--bootstrap", type=int, default=1000)
    evaluate.set_defaults(func=command_eval)

    calibrate = sub.add_parser("calibrate")
    calibrate.add_argument("gold")
    calibrate.add_argument("pred")
    calibrate.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    calibrate.add_argument("--out", default="thresholds.json")
    calibrate.add_argument("--min-pos", type=int, default=5)
    calibrate.add_argument("--min-precision", type=float, default=0.85)
    calibrate.set_defaults(func=command_calibrate)

    compare = sub.add_parser("compare")
    compare.add_argument("gold")
    compare.add_argument("pred_a")
    compare.add_argument("pred_b")
    compare.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    compare.add_argument("--thresholds", default=None)
    compare.add_argument("--bootstrap", type=int, default=1000)
    compare.set_defaults(func=command_compare)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
