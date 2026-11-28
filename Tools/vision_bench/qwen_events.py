#!/usr/bin/env python3
"""用本地 Qwen3-VL 4B 对候选事件做三元组抽取，并生成人工核对页。

候选事件 = 从真实图库金标集里分层抽出的照片（每张当一条候选事件），
三元组 = activity / participants / setting。核对页让标注者逐字段判对错，
必要时写出正确值；打分脚本据此算字段准确率与三元组完全正确率（即 F1）。

产物：
  <out>/images/NNN.jpg     800px 缩略图
  <out>/results.json       Qwen 原始输出 + 事件上下文
  <out>/review.html        人工核对页
  <out>/review.json        核对模板

用法：
  # 1) 抽 150 条候选事件并跑 Qwen3-VL 4B（可断点续跑）
  python3 Tools/vision_bench/qwen_events.py run \
    --gold /private/tmp/luma_real/goldset.json \
    --pred /private/tmp/luma_real/predictions.json \
    --tags Resources/Models/SigLIP2Assets/tags.json \
    --out docs/ai/qwen-events --limit 150

  # 2) 起静态服务，人工核对后导出 review.json

  # 3) 打分
  python3 Tools/vision_bench/qwen_events.py score \
    --out docs/ai/qwen-events --review docs/ai/qwen-events/review.json
"""

import argparse
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from label_sheet import pick, predicted_labels  # noqa: E402
from qwen_compare import PROMPT, chat  # noqa: E402

FIELDS = [("activity", "活动"), ("participants", "参与者"), ("setting", "地点类型")]


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def export_image(source, dest, max_side=800):
    import subprocess
    cmd = ["sips", "-Z", str(max_side), "-s", "format", "jpeg",
           "-s", "formatOptions", "70", source, "--out", dest]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and os.path.exists(dest)


def do_run(args):
    gold = load_json(args.gold)
    pred = load_json(args.pred)
    tags = load_json(args.tags)["tags"]
    poi = {item["path"]: item for item in load_json(args.poi).get("items", [])} if args.poi else {}

    scores_by_id = {item["id"]: item.get("scores", {}) for item in pred["items"]}
    pred_by_id = {item_id: predicted_labels(scores, tags)
                  for item_id, scores in scores_by_id.items()}
    picked = pick(gold["items"], pred_by_id, args.limit)

    out_dir = args.out
    os.makedirs(os.path.join(out_dir, "images"), exist_ok=True)
    results_path = os.path.join(out_dir, "results.json")
    previous = {}
    if os.path.exists(results_path):
        for item in load_json(results_path).get("items", []):
            if item.get("valid"):
                previous[item["id"]] = item

    items = []
    for item in picked:
        dest = os.path.join(out_dir, "images", f"{item['id']}.jpg")
        if not os.path.exists(dest) and not export_image(item["path"], dest):
            continue
        captured = item.get("capturedAt") or ""
        place = poi.get(item["path"]) or {}
        items.append({
            "id": item["id"],
            "path": item["path"],
            "date": captured[:10],
            "gps": bool(item.get("gps")),
            "city": " ".join(filter(None, [place.get("administrativeArea"), place.get("locality")])),
            "poi": " · ".join(filter(None, place.get("areasOfInterest") or [])),
            "slice": item.get("slice") or {},
            "siglip": pred_by_id.get(item["id"], []),
            "reason": item.get("_reason", ""),
        })

    model = args.model
    done = 0
    for index, row in enumerate(items, start=1):
        cached = previous.get(row["id"])
        if cached:
            row["qwen"] = cached.get("qwen")
            row["valid"] = cached.get("valid")
            row["seconds"] = cached.get("seconds")
            continue
        image_path = os.path.join(out_dir, "images", f"{row['id']}.jpg")
        with open(image_path, "rb") as handle:
            encoded = base64.b64encode(handle.read()).decode()
        try:
            answer = chat(model, encoded, ctx=args.ctx, max_predict=args.max_predict)
        except Exception as error:  # 单条失败不中断整批
            answer = {"json": None, "valid": False, "seconds": 0.0, "error": str(error)}
        row["qwen"] = answer.get("json")
        row["valid"] = bool(answer.get("valid"))
        row["seconds"] = answer.get("seconds")
        if not row["valid"]:
            print(f"  [{index}/{len(items)}] {row['id']} BAD {answer.get('error', '')[:80]}")
            continue
        done += 1
        print(f"  [{index}/{len(items)}] {row['id']} {answer.get('seconds')}s "
              f"{json.dumps(answer['json'], ensure_ascii=False)}")
        if done % 10 == 0:
            write_results(results_path, model, items)

    write_results(results_path, model, items)
    build_review(items, out_dir)

    valid = sum(1 for row in items if row.get("valid"))
    print(f"\n候选事件 {len(items)} 条，Qwen 有效输出 {valid} 条 → {results_path}")
    print(f"核对页 {os.path.join(out_dir, 'review.html')}")


def write_results(path, model, items):
    payload = {
        "model": model,
        "prompt": PROMPT,
        "normalization": "字段：对=1；错=0；修正值可选",
        "items": items,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)


def build_review(items, out_dir):
    rows_json = json.dumps([{
        "id": row["id"],
        "date": row.get("date", ""),
        "gps": row.get("gps"),
        "city": row.get("city", ""),
        "poi": row.get("poi", ""),
        "siglip": row.get("siglip", []),
        "reason": row.get("reason", ""),
        "qwen": row.get("qwen") or {},
    } for row in items], ensure_ascii=False)
    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>拾光 · Qwen3-VL 事件三元组核对</title>
<style>
  :root{{--bg:#F7F5F1;--card:#FFFDFA;--ink:#17161C;--ink2:#5A5566;--line:rgba(23,22,28,.12);
    --ok:#2B7A55;--bad:#A5262F;--accent:#8E6CF0;--chip:#F1EDE6;}}
  *{{box-sizing:border-box}}
  body{{margin:0;background:var(--bg);color:var(--ink);
    font:14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}}
  header{{position:sticky;top:0;z-index:9;background:rgba(247,245,241,.94);
    backdrop-filter:blur(14px);border-bottom:1px solid var(--line);padding:12px 20px;
    display:flex;gap:14px;align-items:center;flex-wrap:wrap}}
  header b{{font-size:15px}}
  .hint{{color:var(--ink2);font-size:12.5px}}
  .grow{{flex:1}}
  button{{font:inherit;border:1px solid var(--line);background:#fff;border-radius:9px;
    padding:6px 12px;cursor:pointer}}
  button.primary{{background:var(--ink);color:#fff;border-color:var(--ink)}}
  #progress{{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600}}
  main{{max-width:1180px;margin:0 auto;padding:18px 20px 80px;
    display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:16px}}
  .card{{background:var(--card);border:1px solid var(--line);border-radius:14px;
    overflow:hidden;display:flex;flex-direction:column}}
  .card.done{{outline:2px solid var(--ok);outline-offset:-2px}}
  .shot{{background:#0e0d12;display:flex;align-items:center;justify-content:center}}
  .shot img{{width:100%;max-height:300px;object-fit:contain;display:block}}
  .body{{padding:10px 12px 12px;display:flex;flex-direction:column;gap:8px}}
  .meta{{font-size:11.5px;color:var(--ink2);display:flex;gap:8px;flex-wrap:wrap}}
  .meta i{{font-style:normal;background:var(--chip);border-radius:6px;padding:1px 6px}}
  .field{{border-top:1px dashed var(--line);padding-top:7px}}
  .field .top{{display:flex;gap:8px;align-items:center;flex-wrap:wrap}}
  .field .name{{font-size:12px;color:var(--ink2);min-width:60px}}
  .field .val{{font-weight:600}}
  .field .acts{{margin-left:auto;display:flex;gap:5px}}
  .field button{{padding:3px 9px;font-size:12px}}
  .field button.ok.on{{background:#E3F1E9;border-color:var(--ok);color:var(--ok)}}
  .field button.bad.on{{background:#FBE7E8;border-color:var(--bad);color:var(--bad)}}
  .field input{{width:100%;font:inherit;font-size:12.5px;padding:5px 8px;border-radius:8px;
    border:1px solid var(--line);background:#fff;margin-top:6px;display:none}}
  .field input.show{{display:block}}
  .allok{{font-size:12.5px}}
</style>
</head>
<body>
<header>
  <b>Qwen3-VL 事件三元组核对</b>
  <span class="hint">逐字段判「对 / 错」；错就顺手写正确值。三元组 = 活动 · 参与者 · 地点类型。自动存本机。</span>
  <span class="grow"></span>
  <span>进度 <span id="progress">0/0</span></span>
  <button onclick="downloadJSON()" class="primary">导出 review.json</button>
  <button onclick="copyJSON()">复制 JSON</button>
  <button onclick="resetAll()">清空</button>
</header>
<main id="grid"></main>
<script>
const ROWS = {rows_json};
const FIELDS = [["activity","活动"],["participants","参与者"],["setting","地点类型"]];
const KEY = "luma-qwen-events-v1";
const state = JSON.parse(localStorage.getItem(KEY) || "{{}}");

function save() {{ localStorage.setItem(KEY, JSON.stringify(state)); }}
function entry(id) {{
  if (!state[id]) state[id] = {{ fields: {{}}, note: "" }};
  if (!state[id].fields) state[id].fields = {{}};
  FIELDS.forEach(([key]) => {{
    if (!state[id].fields[key]) state[id].fields[key] = {{ ok: null, fix: "" }};
  }});
  return state[id];
}}
function complete(id) {{
  const st = entry(id);
  return FIELDS.every(([key]) => st.fields[key].ok !== null);
}}
function updateProgress() {{
  const done = ROWS.filter(r => complete(r.id)).length;
  document.getElementById("progress").textContent = done + "/" + ROWS.length;
}}

function render() {{
  const y = window.scrollY;
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  ROWS.forEach(r => {{
    const st = entry(r.id);
    const card = document.createElement("div");
    card.className = "card" + (complete(r.id) ? " done" : "");
    const meta = [];
    meta.push(`<span><b>#${{r.id}}</b></span>`);
    meta.push(`<i>${{r.date || "无日期"}}</i>`);
    meta.push(`<i>${{r.gps ? "有 GPS" : "无 GPS"}}</i>`);
    if (r.city) meta.push(`<i>${{r.city}}</i>`);
    if (r.poi) meta.push(`<i>${{r.poi}}</i>`);
    if (r.reason) meta.push(`<i>${{r.reason}}</i>`);
    card.innerHTML = `
      <div class="shot"><img loading="lazy" src="images/${{r.id}}.jpg" alt="${{r.id}}"></div>
      <div class="body">
        <div class="meta">${{meta.join("")}}</div>
        <div class="qwen"></div>
      </div>`;
    const box = card.querySelector(".qwen");
    FIELDS.forEach(([key, label]) => {{
      const f = st.fields[key];
      const value = (r.qwen && r.qwen[key]) || "（空）";
      const row = document.createElement("div");
      row.className = "field";
      row.innerHTML = `
        <div class="top">
          <span class="name">${{label}}</span>
          <span class="val">${{value}}</span>
          <span class="acts">
            <button class="ok${{f.ok === true ? " on" : ""}}">✔ 对</button>
            <button class="bad${{f.ok === false ? " on" : ""}}">✘ 错</button>
          </span>
        </div>
        <input placeholder="正确值是？（可选）" value="${{f.fix || ""}}" class="${{f.ok === false ? "show" : ""}}">`;
      row.querySelector(".ok").onclick = () => {{
        f.ok = true; f.fix = ""; save(); render();
      }};
      row.querySelector(".bad").onclick = () => {{
        f.ok = false; save(); render();
      }};
      const fix = row.querySelector("input");
      fix.onchange = () => {{ f.fix = fix.value; save(); }};
      box.appendChild(row);
    }});
    const note = document.createElement("input");
    note.className = "field";
    note.style.border = "1px solid var(--line)";
    note.style.borderRadius = "8px";
    note.style.padding = "5px 8px";
    note.placeholder = "备注（可选）";
    note.value = st.note || "";
    note.onchange = () => {{ st.note = note.value; save(); }};
    box.appendChild(note);
    const status = document.createElement("span");
    status.className = "allok hint";
    status.textContent = complete(r.id) ? "已核对" : "还有字段未判";
    box.appendChild(status);
    grid.appendChild(card);
  }});
  updateProgress();
  window.scrollTo(0, y);
}}

function payload() {{
  return {{
    generatedAt: new Date().toISOString(),
    count: ROWS.length,
    items: ROWS.map(r => ({{
      id: r.id,
      qwen: r.qwen || {{}},
      fields: entry(r.id).fields,
      note: entry(r.id).note || "",
      complete: complete(r.id),
    }}))
  }};
}}
function downloadJSON() {{
  const blob = new Blob([JSON.stringify(payload(), null, 2)], {{type: "application/json"}});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "review.json";
  a.click();
}}
function copyJSON() {{
  navigator.clipboard.writeText(JSON.stringify(payload(), null, 2));
  alert("已复制到剪贴板");
}}
function resetAll() {{
  if (!confirm("清空全部核对？")) return;
  Object.keys(state).forEach(k => delete state[k]);
  save(); render();
}}
render();
</script>
</body>
</html>
"""
    with open(os.path.join(out_dir, "review.html"), "w", encoding="utf-8") as handle:
        handle.write(html)
    template = {
        "generatedAt": None,
        "count": len(items),
        "items": [{"id": row["id"], "fields": {}, "note": ""} for row in items],
    }
    with open(os.path.join(out_dir, "review.json"), "w", encoding="utf-8") as handle:
        json.dump(template, handle, ensure_ascii=False, indent=2)


def lcs(a, b):
    if not a or not b:
        return 0
    previous = [0] * (len(b) + 1)
    for char in a:
        current = [0]
        for index, other in enumerate(b, start=1):
            current.append(previous[index - 1] + 1 if char == other else max(previous[index], current[-1]))
        previous = current
    return previous[-1]


def similarity(pred, gold):
    if not pred or not gold:
        return 0.0
    return 2 * lcs(pred, gold) / (len(pred) + len(gold))


def do_score(args):
    results = load_json(os.path.join(args.out, "results.json"))
    review = load_json(args.review)
    qwen = {item["id"]: item for item in results.get("items", [])}
    reviewed = [item for item in review.get("items", []) if item.get("complete")]
    if not reviewed:
        print("FAIL review.json 里没有已核对的条目")
        sys.exit(2)

    per_field = {key: {"tp": 0, "fp": 0, "fn": 0, "fixes": []} for key, _ in FIELDS}
    triplet = {"ok": 0, "partial": 0}
    for item in reviewed:
        row = qwen.get(item["id"], {})
        answer = row.get("qwen") or {}
        all_ok = True
        for key, label in FIELDS:
            verdict = (item.get("fields") or {}).get(key) or {}
            if verdict.get("ok") is None:
                all_ok = False
                continue
            if verdict.get("ok"):
                per_field[key]["tp"] += 1
            else:
                per_field[key]["fp"] += 1
                all_ok = False
                fix = (verdict.get("fix") or "").strip()
                if fix:
                    per_field[key]["fn"] += 1
                    per_field[key]["fixes"].append({
                        "id": item["id"], "pred": answer.get(key, ""), "fix": fix,
                        "similarity": round(similarity(str(answer.get(key, "")), fix), 2),
                    })
        if all_ok:
            triplet["ok"] += 1
        else:
            triplet["partial"] += 1

    total = len(reviewed)
    print(f"已核对 {total} 条 / 候选中 {len(results.get('items', []))} 条")
    print(f"\n{'字段':<8}{'TP':>5}{'FP':>5}{'FN':>5}{'准确率':>9}{'F1':>8}")
    for key, label in FIELDS:
        row = per_field[key]
        tp, fp, fn = row["tp"], row["fp"], row["fn"]
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        print(f"{label:<8}{tp:>5}{fp:>5}{fn:>5}{precision:>9.3f}{f1:>8.3f}")
        row["precision"] = precision
        row["recall"] = recall
        row["f1"] = f1

    exact = triplet["ok"] / total
    print(f"\n三元组完全正确 {triplet['ok']}/{total} = {exact:.3f}")
    print("（每条事件模型都给一个三元组、人工给一个判定：三元组 F1 = 完全正确率）")
    for key, label in FIELDS:
        fixes = per_field[key]["fixes"]
        if fixes:
            print(f"\n{label} 错误样例（前 8 条）：")
            for row in fixes[:8]:
                print(f"  #{row['id']}  模型「{row['pred']}」→ 应为「{row['fix']}」")

    report = {
        "reviewed": total,
        "candidates": len(results.get("items", [])),
        "tripletExact": round(exact, 3),
        "fields": {key: {k: v for k, v in row.items() if k != "fixes"} for key, row in per_field.items()},
    }
    out_path = os.path.join(args.out, "score.json")
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(f"\n写入 {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Qwen3-VL 候选事件三元组抽取与核对")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run")
    run.add_argument("--gold", default="/private/tmp/luma_real/goldset.json")
    run.add_argument("--pred", default="/private/tmp/luma_real/predictions.json")
    run.add_argument("--tags", default="Resources/Models/SigLIP2Assets/tags.json")
    run.add_argument("--poi", default="/private/tmp/luma_real/poi.json")
    run.add_argument("--out", default="docs/ai/qwen-events")
    run.add_argument("--limit", type=int, default=150)
    run.add_argument("--model", default="luma-qwen3vl:4b")
    run.add_argument("--ctx", type=int, default=8192)
    run.add_argument("--max-predict", type=int, default=128)
    run.set_defaults(func=do_run)

    score = sub.add_parser("score")
    score.add_argument("--out", default="docs/ai/qwen-events")
    score.add_argument("--review", default="docs/ai/qwen-events/review.json")
    score.set_defaults(func=do_score)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
