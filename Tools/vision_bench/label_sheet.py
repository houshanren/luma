#!/usr/bin/env python3
"""从真实图库金标集里抽样，导出缩略图与人工标注页。

输入（由 goldset_sample / vision_predict 产生）：
  goldset.json     待标注样本
  predictions.json 249 标签分数
  tags.json        标签定义（id / title / threshold）

输出：
  <out>/images/NNN.jpg     1024px 缩略图
  <out>/index.html         标注页（纯本地、无依赖）
  <out>/labeled.json       人工标注模板（labels 为空，供评测脚本读取）

两种标注模式：
  默认      显示模型预测标签，点选即接受；只能测精度，召回恒为 1。
  --blind   不显示预测标签，自己写标签；标记完成后才展开预测。
            这样才能测真实召回；导出内容带 mode="blind"。

用法：
  # 常规 40 张（显示预测）
  python3 Tools/vision_bench/label_sheet.py \
    /private/tmp/luma_real/goldset.json \
    /private/tmp/luma_real/predictions.json \
    Resources/Models/SigLIP2Assets/tags.json \
    docs/ai/goldset-40

  # 盲标 200 张（排除已标注的 40 张）
  python3 Tools/vision_bench/label_sheet.py \
    /private/tmp/luma_real/goldset.json \
    /private/tmp/luma_real/predictions.json \
    Resources/Models/SigLIP2Assets/tags.json \
    docs/ai/goldset-200 --target 200 --blind \
    --exclude-labels docs/ai/goldset-40/labels.json
"""

import argparse
import json
import os
import random
import subprocess
from datetime import datetime

TARGET = 40
SEED = 20261128


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def predicted_labels(scores, tags, limit=12):
    """按 tags.json 的阈值取标签，再按分数截断到 top-12（近似 App 的组内限额）。"""
    hits = []
    for tag in tags:
        value = scores.get(tag["id"])
        if value is None:
            continue
        if value >= tag["threshold"]:
            hits.append((value, tag["title"]))
    hits.sort(reverse=True)
    return [title for _, title in hits[:limit]]


def pick(items, pred_by_id, target, exclude=frozenset()):
    """分层抽样：先保证高价值标签覆盖，再按 GPS / 人数 / 夜景 / 零标签分层补齐。"""
    rng = random.Random(SEED)
    items = [item for item in items if item["id"] not in exclude]
    picked = []
    used = set()

    def add(item, reason):
        used.add(item["id"])
        item["_reason"] = reason
        picked.append(item)

    def take(pool, count, reason):
        bucket = [item for item in pool if item["id"] not in used]
        rng.shuffle(bucket)
        for item in bucket[:count]:
            add(item, reason)

    def has(label):
        return [item for item in items if label in pred_by_id.get(item["id"], [])]

    # 1) 标签覆盖：每个高价值标签按样本量等比分配，至少 1 张。
    coverage = ["亲子互动", "美食", "旅游", "古迹", "团建", "看展", "庙会", "住民宿",
                "婚礼现场", "海边", "山脉", "湖泊", "天空", "文档", "截图", "汽车"]
    per_label = max(1, round(target / 40 * 5))
    for label in coverage:
        take(has(label), per_label, label)

    # 2) 结构分层：GPS / 人数 / 光照 / 零标签，按样本量等比放大。
    factor = target / 40.0
    with_gps = [i for i in items if i.get("gps")]
    no_gps = [i for i in items if not i.get("gps")]
    groups = [i for i in items if (i.get("slice") or {}).get("faces") == "group"]
    people = [i for i in items if (i.get("slice") or {}).get("faces") == "people"]
    solo = [i for i in items if (i.get("slice") or {}).get("faces") == "none"]
    night = [i for i in items if (i.get("slice") or {}).get("light") == "night"]
    zero = [i for i in items if not pred_by_id.get(i["id"])]

    take(with_gps, round(6 * factor), "有 GPS")
    take(no_gps, round(6 * factor), "无 GPS")
    take(groups, round(6 * factor), "合影")
    take(people, round(6 * factor), "有人")
    take(solo, round(6 * factor), "无人")
    take(night, round(3 * factor), "夜景")
    take(zero, round(4 * factor), "零标签")

    # 3) 仍不足则随机补齐。
    rest = [i for i in items if i["id"] not in used]
    rng.shuffle(rest)
    for item in rest:
        if len(picked) >= target:
            break
        add(item, "补齐")

    return picked[:target]


def export_image(source, dest, max_side=1024):
    cmd = ["sips", "-Z", str(max_side), "-s", "format", "jpeg",
           "-s", "formatOptions", "70", source, "--out", dest]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and os.path.exists(dest)


def build_html(rows, all_titles, state_key, blind=False):
    titles_json = json.dumps(all_titles, ensure_ascii=False)
    rows_json = json.dumps(rows, ensure_ascii=False)
    blind_json = "true" if blind else "false"
    title = "盲标" if blind else "人工标注"
    hint = ("自己写标签，不看模型预测；标完才展开预测做对照。"
            if blind else
            "点标签 = 认为正确；灰色为模型预测（含 Apple 第二信号）。漏掉的用输入框补。")
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>拾光 · {len(rows)} 张{title}</title>
<style>
  :root{{--bg:#F7F5F1;--card:#FFFDFA;--ink:#17161C;--ink2:#5A5566;--line:rgba(23,22,28,.12);
    --ok:#2B7A55;--warn:#9A6B12;--chip:#F1EDE6;--accent:#8E6CF0;}}
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
    display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:16px}}
  .card{{background:var(--card);border:1px solid var(--line);border-radius:14px;
    overflow:hidden;display:flex;flex-direction:column}}
  .card.done{{outline:2px solid var(--ok);outline-offset:-2px}}
  .shot{{background:#0e0d12;display:flex;align-items:center;justify-content:center}}
  .shot img{{width:100%;max-height:300px;object-fit:contain;display:block}}
  .body{{padding:10px 12px 12px;display:flex;flex-direction:column;gap:8px}}
  .meta{{font-size:11.5px;color:var(--ink2);display:flex;gap:8px;flex-wrap:wrap}}
  .meta i{{font-style:normal;background:var(--chip);border-radius:6px;padding:1px 6px}}
  .chips{{display:flex;gap:5px;flex-wrap:wrap}}
  .chip{{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:2px 9px;
    cursor:pointer;user-select:none;background:#fff}}
  .chip.on{{background:#EFE9FF;border-color:var(--accent);color:#4B2FB8}}
  .chip.pred{{cursor:default;color:var(--ink2);border-style:dashed}}
  .chip.pred.hit{{background:#E3F1E9;border-color:var(--ok);color:var(--ok);border-style:solid}}
  .chip.unknown{{background:#FBE7E8;border-color:#A5262F;color:#A5262F}}
  .extra{{display:flex;gap:6px}}
  .extra input{{flex:1;font:inherit;font-size:12.5px;padding:5px 8px;border-radius:8px;
    border:1px solid var(--line);background:#fff}}
  .row{{display:flex;gap:6px;align-items:center;flex-wrap:wrap}}
  .note{{font-size:12px;padding:5px 8px;border-radius:8px;border:1px solid var(--line);
    width:100%;background:#fff;font:inherit}}
  .status{{font-size:11.5px;color:var(--ok)}}
  .predbox{{display:none;border-top:1px dashed var(--line);padding-top:8px}}
  .predbox.show{{display:block}}
  .predbox .label{{font-size:11.5px;color:var(--ink2);margin-bottom:4px}}
  .warn{{font-size:11.5px;color:#A5262F}}
</style>
</head>
<body>
<header>
  <b>{len(rows)} 张{title}</b>
  <span class="hint">{hint}</span>
  <span class="grow"></span>
  <span>进度 <span id="progress">0/0</span></span>
  <button onclick="setFilter('all')">全部</button>
  <button onclick="setFilter('todo')">只未标</button>
  <button onclick="setFilter('done')">只已标</button>
  <button onclick="downloadJSON()" class="primary">导出 labels.json</button>
  <button onclick="copyJSON()">复制 JSON</button>
  <button onclick="resetAll()">清空</button>
</header>
<main id="grid"></main>
<datalist id="alltitles"></datalist>
<script>
const ROWS = {rows_json};
const ALL_TITLES = {titles_json};
const BLIND = {blind_json};
const KEY = "{state_key}";
const state = JSON.parse(localStorage.getItem(KEY) || "{{}}");
const TITLE_SET = new Set(ALL_TITLES);
let filter = "all";
document.getElementById("alltitles").innerHTML =
  ALL_TITLES.map(t => `<option value="${{t}}">`).join("");

function save() {{ localStorage.setItem(KEY, JSON.stringify(state)); }}
function entry(id) {{
  if (!state[id]) state[id] = {{ labels: [], note: "", done: false, revealed: false, editedAfterReveal: false }};
  const st = state[id];
  if (!Array.isArray(st.labels)) st.labels = [];
  return st;
}}
function updateProgress() {{
  const done = ROWS.filter(r => entry(r.id).done).length;
  document.getElementById("progress").textContent = done + "/" + ROWS.length;
}}
function setFilter(value) {{ filter = value; render(); }}

function addLabels(id, text) {{
  text.split(/[，,、\\s]+/).filter(Boolean).forEach(label => {{
    const st = entry(id);
    if (!st.labels.includes(label)) st.labels.push(label);
    if (st.done) st.editedAfterReveal = true;
  }});
  save(); render();
}}

function render() {{
  const y = window.scrollY;
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  ROWS.forEach(r => {{
    const st = entry(r.id);
    if (filter === "todo" && st.done) return;
    if (filter === "done" && !st.done) return;
    const card = document.createElement("div");
    card.className = "card" + (st.done ? " done" : "");
    card.innerHTML = `
      <div class="shot"><img loading="lazy" src="images/${{r.id}}.jpg" alt="${{r.id}}"></div>
      <div class="body">
        <div class="meta">
          <span><b>#${{r.id}}</b></span>
          <i>${{r.date || "无日期"}}</i>
          <i>${{r.gps ? "有 GPS" : "无 GPS"}}</i>
          <i>${{r.reason}}</i>
        </div>
        <div class="chips"></div>
        <div class="extra">
          <input placeholder="${{BLIND ? "你看到什么标签？逗号分隔" : "补充标签，逗号分隔"}}" value="">
          <button>加</button>
        </div>
        <input class="note" placeholder="备注（可选，例如：地点/人物关系）" value="${{st.note}}">
        <span class="status"></span>
        <div class="row">
          <button class="ok">${{st.done ? "↩ 撤销" : "✔ 这张标完了"}}</button>
          <span class="hint">已选 ${{(st.labels || []).length}} 个</span>
        </div>
        <div class="predbox${{st.done ? " show" : ""}}">
          <div class="label">模型预测${{BLIND ? "（标完后对照，只读）" : ""}}</div>
          <div class="chips predchips"></div>
        </div>
      </div>`;

    const chips = card.querySelector(".chips");
    (st.labels || []).forEach(label => {{
      const chip = document.createElement("span");
      chip.className = "chip on" + (TITLE_SET.has(label) ? "" : " unknown");
      chip.textContent = label + " ×";
      chip.title = TITLE_SET.has(label) ? "点击移除" : "不在标签表里（会按未命中计）";
      chip.onclick = () => {{
        const list = entry(r.id).labels;
        const idx = list.indexOf(label);
        if (idx >= 0) list.splice(idx, 1);
        if (entry(r.id).done) entry(r.id).editedAfterReveal = true;
        save(); render();
      }};
      chips.appendChild(chip);
    }});

    if (BLIND) {{
      const unknown = (st.labels || []).filter(l => !TITLE_SET.has(l));
      if (unknown.length) {{
        const warn = document.createElement("span");
        warn.className = "warn";
        warn.textContent = "非标准标签 " + unknown.length + " 个，建议改成下拉里的写法";
        card.querySelector(".body").insertBefore(warn, card.querySelector(".note"));
      }}
    }} else {{
      r.predicted.forEach(label => {{
        const chip = document.createElement("span");
        chip.className = "chip" + ((st.labels || []).includes(label) ? " on" : "");
        chip.textContent = label;
        chip.onclick = () => {{
          const list = entry(r.id).labels;
          const idx = list.indexOf(label);
          if (idx >= 0) list.splice(idx, 1); else list.push(label);
          if (entry(r.id).done) entry(r.id).editedAfterReveal = true;
          save(); render();
        }};
        chips.appendChild(chip);
      }});
    }}

    if (st.done) {{
      const pred = card.querySelector(".predchips");
      r.predicted.forEach(label => {{
        const chip = document.createElement("span");
        chip.className = "chip pred" + ((st.labels || []).includes(label) ? " hit" : "");
        chip.textContent = label;
        pred.appendChild(chip);
      }});
      if (!r.predicted.length) pred.textContent = "（无预测）";
      const missed = (st.labels || []).filter(l => !r.predicted.includes(l));
      const hit = (st.labels || []).filter(l => r.predicted.includes(l)).length;
      card.querySelector(".status").textContent =
        `模型 ${{r.predicted.length}} 个，命中 ${{hit}} 个` + (missed.length ? `，漏 ${{missed.length}} 个` : "");
    }}

    const extraInput = card.querySelector(".extra input");
    const extraBtn = card.querySelector(".extra button");
    const addExtra = () => {{
      if (!extraInput.value.trim()) return;
      addLabels(r.id, extraInput.value);
    }};
    extraBtn.onclick = addExtra;
    extraInput.onkeydown = e => {{ if (e.key === "Enter") addExtra(); }};

    const note = card.querySelector(".note");
    note.onchange = () => {{ entry(r.id).note = note.value; save(); }};

    card.querySelector(".ok").onclick = () => {{
      const e2 = entry(r.id);
      e2.done = !e2.done;
      if (e2.done) e2.revealed = true;
      save(); render();
    }};
    if (!st.done) card.querySelector(".status").textContent = "";
    grid.appendChild(card);
  }});
  updateProgress();
  window.scrollTo(0, y);
}}

function payload() {{
  return {{
    generatedAt: new Date().toISOString(),
    mode: BLIND ? "blind" : "assisted",
    count: ROWS.length,
    items: ROWS.map(r => {{
      const st = entry(r.id);
      return {{ id: r.id, file: r.file, predicted: r.predicted,
               labels: st.labels || [], note: st.note || "", done: !!st.done,
               revealed: !!st.revealed, editedAfterReveal: !!st.editedAfterReveal }};
    }})
  }};
}}
function downloadJSON() {{
  const blob = new Blob([JSON.stringify(payload(), null, 2)], {{type: "application/json"}});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "labels.json";
  a.click();
}}
function copyJSON() {{
  navigator.clipboard.writeText(JSON.stringify(payload(), null, 2));
  alert("已复制到剪贴板");
}}
function resetAll() {{
  if (!confirm("清空全部标注？")) return;
  Object.keys(state).forEach(k => delete state[k]);
  save(); render();
}}
render();
</script>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description="导出真实图库人工标注页")
    parser.add_argument("gold")
    parser.add_argument("pred")
    parser.add_argument("tags")
    parser.add_argument("out", nargs="?", default="docs/ai/goldset-40")
    parser.add_argument("--target", type=int, default=TARGET,
                        help="抽样张数，默认 40")
    parser.add_argument("--blind", action="store_true",
                        help="盲标：不显示预测标签，标完才展开")
    parser.add_argument("--exclude-labels", default=None,
                        help="已有 labels.json，排除其中 done=true 的样本")
    args = parser.parse_args()

    gold = load_json(args.gold)
    pred = load_json(args.pred)
    catalog = load_json(args.tags)
    tags = catalog["tags"]

    exclude = set()
    if args.exclude_labels and os.path.exists(args.exclude_labels):
        previous = load_json(args.exclude_labels)
        exclude = {item["id"] for item in previous.get("items", []) if item.get("done")}
        print(f"排除已标注 {len(exclude)} 张")

    scores_by_id = {item["id"]: item.get("scores", {}) for item in pred["items"]}
    pred_by_id = {item_id: predicted_labels(scores, tags)
                  for item_id, scores in scores_by_id.items()}

    picked = pick(gold["items"], pred_by_id, args.target, exclude)

    os.makedirs(os.path.join(args.out, "images"), exist_ok=True)
    rows = []
    failed = []
    for item in picked:
        dest = os.path.join(args.out, "images", f"{item['id']}.jpg")
        if not export_image(item["path"], dest):
            failed.append(item["id"])
            continue
        captured = item.get("capturedAt") or ""
        rows.append({
            "id": item["id"],
            "file": os.path.relpath(item["path"], "/Volumes"),
            "path": item["path"],
            "date": captured[:10] if captured else "",
            "gps": bool(item.get("gps")),
            "faces": (item.get("slice") or {}).get("faces", ""),
            "reason": item.get("_reason", ""),
            "predicted": pred_by_id.get(item["id"], []),
        })

    titles = sorted({tag["title"] for tag in tags})
    state_key = f"luma-label-{args.target}-{'blind' if args.blind else 'v1'}"
    html = build_html(rows, titles, state_key, args.blind)
    with open(os.path.join(args.out, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(html)

    template = {
        "createdAt": datetime.now().isoformat(timespec="seconds"),
        "source": os.path.abspath(args.gold),
        "mode": "blind" if args.blind else "assisted",
        "count": len(rows),
        "items": [{"id": r["id"], "file": r["file"], "path": r["path"],
                   "labels": [], "note": ""} for r in rows],
    }
    with open(os.path.join(args.out, "labeled.json"), "w", encoding="utf-8") as handle:
        json.dump(template, handle, ensure_ascii=False, indent=2)

    print(f"导出 {len(rows)} 张 → {args.out}{'（盲标）' if args.blind else ''}")
    if failed:
        print(f"跳过 {len(failed)} 张（sips 失败）：{', '.join(failed)}")
    print(f"打开 {os.path.join(args.out, 'index.html')} 开始标注")


if __name__ == "__main__":
    main()
