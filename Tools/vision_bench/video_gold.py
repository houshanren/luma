#!/usr/bin/env python3
"""视频金标：从真实图库抽视频、抽 5 帧、跑逐帧 SigLIP、生成人工标注页。

背景：图库里约 3.6 万条视频从未评测。App 的视频链路是「5%–95% 均匀取 4–6 帧 →
每帧复用照片管线 → 标签按出现频次聚合」，这里用同样的思路做离线金标。

产物：
  <out>/frames/v0001_f0.jpg …   每条视频 5 帧（640px）
  <out>/items.json              视频清单 + 帧级标签聚合（供核对页与评测）
  <out>/video_goldset.json      标注模板（labels 为空）
  <out>/video_predictions.json  视频级 scores（取帧内最大分），可直接喂 goldset_eval
  <out>/review.html             人工标注页（盲标，标完展开模型标签）

用法：
  python3 Tools/vision_bench/video_gold.py run --limit 120 --out docs/ai/video-gold
"""

import argparse
import json
import os
import random
import subprocess
import sys
from datetime import datetime

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FFMPEG = os.path.join(ROOT, "Vendor/ffmpeg/ffmpeg")
FFPROBE = os.path.join(ROOT, "Vendor/ffmpeg/ffprobe")
PREDICTOR = "/tmp/vision_predict"
ORIGINALS = os.environ.get("LUMA_ORIGINALS", "")
TAGS = "Resources/Models/SigLIP2Assets/tags.json"
MODEL_DIR = os.path.expanduser("~/Library/Application Support/Luma/Models/SigLIP2")

VIDEO_EXTS = {".mov", ".MOV", ".mp4", ".MP4", ".m4v", ".M4V"}
FRAME_POINTS = (0.08, 0.29, 0.50, 0.71, 0.92)
MIN_SECONDS = 2.5


def scan_videos(root):
    videos = []
    for entry in os.scandir(root):
        if not entry.is_dir():
            continue
        for file in os.scandir(entry.path):
            if os.path.splitext(file.name)[1] in VIDEO_EXTS:
                videos.append(file.path)
    return sorted(videos)


def probe_seconds(path):
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=20).stdout.strip()
        return float(out)
    except Exception:
        return 0.0


def extract_frame(source, seconds, dest):
    cmd = [FFMPEG, "-nostdin", "-v", "error", "-ss", f"{seconds:.2f}", "-i", source,
           "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "4", "-y", dest]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 0


def pick_videos(videos, limit, seed=20261128, pool=1200):
    """按视频时长分层，避免全是几秒的 Live Photo 或全是长视频。"""
    rng = random.Random(seed)
    candidates = rng.sample(videos, min(len(videos), pool))
    probed = []
    for path in candidates:
        seconds = probe_seconds(path)
        if seconds >= MIN_SECONDS:
            probed.append((path, seconds))
    buckets = {"short": [], "medium": [], "long": [], "verylong": []}
    for path, seconds in probed:
        if seconds < 10:
            buckets["short"].append((path, seconds))
        elif seconds < 60:
            buckets["medium"].append((path, seconds))
        elif seconds < 300:
            buckets["long"].append((path, seconds))
        else:
            buckets["verylong"].append((path, seconds))
    quota = {"short": 25, "medium": 45, "long": 35, "verylong": 15}
    picked = []
    for name in buckets:
        rng.shuffle(buckets[name])
        picked.extend(buckets[name][:quota[name]])
    if len(picked) < limit:
        used = {path for path, _ in picked}
        rest = [(path, seconds) for path, seconds in probed if path not in used]
        rng.shuffle(rest)
        picked.extend(rest[: limit - len(picked)])
    picked = picked[:limit]
    picked.sort(key=lambda pair: pair[0])
    return picked


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def aggregate_frames(predictions, tags, frame_count):
    """视频级分数 = 各帧最大分；视频级标签 = 过半数帧命中。"""
    scores = {}
    hits = {}
    for item in predictions.get("items", []):
        for tag_id, value in (item.get("scores") or {}).items():
            scores[tag_id] = max(scores.get(tag_id, -1.0), float(value))
    for tag in tags:
        count = 0
        for item in predictions.get("items", []):
            value = (item.get("scores") or {}).get(tag["id"], -1.0)
            if float(value) >= float(tag.get("threshold") or 0.085):
                count += 1
        if count * 2 > frame_count:
            hits[tag["title"]] = count
    return scores, hits


def build_html(items, all_titles, out_dir):
    rows_json = json.dumps(items, ensure_ascii=False)
    titles_json = json.dumps(all_titles, ensure_ascii=False)
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>拾光 · 视频金标 {len(items)} 条</title>
<style>
  :root{{--bg:#F7F5F1;--card:#FFFDFA;--ink:#17161C;--ink2:#5A5566;--line:rgba(23,22,28,.12);
    --ok:#2B7A55;--accent:#8E6CF0;--chip:#F1EDE6;}}
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
  main{{max-width:1240px;margin:0 auto;padding:18px 20px 80px;
    display:grid;grid-template-columns:repeat(auto-fill,minmax(520px,1fr));gap:16px}}
  .card{{background:var(--card);border:1px solid var(--line);border-radius:14px;
    overflow:hidden;display:flex;flex-direction:column}}
  .card.done{{outline:2px solid var(--ok);outline-offset:-2px}}
  .strip{{display:flex;gap:2px;background:#0e0d12}}
  .strip img{{flex:1;min-width:0;height:190px;object-fit:cover;display:block}}
  .body{{padding:10px 12px 12px;display:flex;flex-direction:column;gap:8px}}
  .meta{{font-size:11.5px;color:var(--ink2);display:flex;gap:8px;flex-wrap:wrap}}
  .meta i{{font-style:normal;background:var(--chip);border-radius:6px;padding:1px 6px}}
  .chips{{display:flex;gap:5px;flex-wrap:wrap}}
  .chip{{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:2px 9px;
    background:#fff;cursor:pointer;user-select:none}}
  .chip.on{{background:#EFE9FF;border-color:var(--accent);color:#4B2FB8}}
  .chip.pred{{cursor:default;color:var(--ink2);border-style:dashed}}
  .chip.pred.hit{{background:#E3F1E9;border-color:var(--ok);color:var(--ok);border-style:solid}}
  .extra{{display:flex;gap:6px}}
  .extra input{{flex:1;font:inherit;font-size:12.5px;padding:5px 8px;border-radius:8px;
    border:1px solid var(--line);background:#fff}}
  .predbox{{display:none;border-top:1px dashed var(--line);padding-top:8px}}
  .predbox.show{{display:block}}
  .predbox .label{{font-size:11.5px;color:var(--ink2);margin-bottom:4px}}
  .status{{font-size:11.5px;color:var(--ok)}}
</style>
</head>
<body>
<header>
  <b>视频金标 {len(items)} 条</b>
  <span class="hint">看 5 帧（8% / 29% / 50% / 71% / 92%），写整条视频的标签；标完才展开模型的聚合标签。</span>
  <span class="grow"></span>
  <span>进度 <span id="progress">0/0</span></span>
  <button onclick="downloadJSON()" class="primary">导出 video_labels.json</button>
  <button onclick="copyJSON()">复制 JSON</button>
  <button onclick="resetAll()">清空</button>
</header>
<main id="grid"></main>
<datalist id="alltitles"></datalist>
<script>
const ROWS = {rows_json};
const ALL_TITLES = {titles_json};
const KEY = "luma-video-gold-120-v1";
const state = JSON.parse(localStorage.getItem(KEY) || "{{}}");
const TITLE_SET = new Set(ALL_TITLES);
document.getElementById("alltitles").innerHTML =
  ALL_TITLES.map(t => `<option value="${{t}}">`).join("");

function save() {{ localStorage.setItem(KEY, JSON.stringify(state)); }}
function entry(id) {{
  if (!state[id]) state[id] = {{ labels: [], done: false }};
  if (!Array.isArray(state[id].labels)) state[id].labels = [];
  return state[id];
}}
function updateProgress() {{
  const done = ROWS.filter(r => entry(r.id).done).length;
  document.getElementById("progress").textContent = done + "/" + ROWS.length;
}}
function addLabels(id, text) {{
  text.split(/[，,、\\s]+/).filter(Boolean).forEach(label => {{
    const st = entry(id);
    if (!st.labels.includes(label)) st.labels.push(label);
  }});
  save(); render();
}}

function render() {{
  const y = window.scrollY;
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  ROWS.forEach(r => {{
    const st = entry(r.id);
    const card = document.createElement("div");
    card.className = "card" + (st.done ? " done" : "");
    card.innerHTML = `
      <div class="strip">${{r.frames.map(f => `<img loading="lazy" src="frames/${{f}}" alt="${{f}}">`).join("")}}</div>
      <div class="body">
        <div class="meta">
          <span><b>#${{r.id}}</b></span>
          <i>${{r.seconds ? r.seconds.toFixed(1) + "s" : "时长未知"}}</i>
          <i>${{r.frames.length}} 帧</i>
        </div>
        <div class="chips"></div>
        <div class="extra">
          <input placeholder="这条视频有什么标签？逗号分隔" value="">
          <button>加</button>
        </div>
        <div class="row" style="display:flex;gap:6px;align-items:center">
          <button class="ok">${{st.done ? "↩ 撤销" : "✔ 这条标完了"}}</button>
          <span class="hint">已选 ${{st.labels.length}} 个</span>
        </div>
        <span class="status"></span>
        <div class="predbox${{st.done ? " show" : ""}}">
          <div class="label">模型（逐帧过阈值且过半帧命中）</div>
          <div class="chips predchips"></div>
        </div>
      </div>`;
    const chips = card.querySelector(".chips");
    st.labels.forEach(label => {{
      const chip = document.createElement("span");
      chip.className = "chip on" + (TITLE_SET.has(label) ? "" : "");
      chip.textContent = label + " ×";
      chip.onclick = () => {{
        const list = entry(r.id).labels;
        const idx = list.indexOf(label);
        if (idx >= 0) list.splice(idx, 1);
        save(); render();
      }};
      chips.appendChild(chip);
    }});
    if (st.done) {{
      const pred = card.querySelector(".predchips");
      r.tags.forEach(label => {{
        const chip = document.createElement("span");
        chip.className = "chip pred" + (st.labels.includes(label) ? " hit" : "");
        chip.textContent = label;
        pred.appendChild(chip);
      }});
      if (!r.tags.length) pred.textContent = "（无预测）";
      const hit = st.labels.filter(l => r.tags.includes(l)).length;
      card.querySelector(".status").textContent =
        `模型 ${{r.tags.length}} 个，命中 ${{hit}} 个，漏 ${{st.labels.length - hit}} 个`;
    }}
    const extraInput = card.querySelector(".extra input");
    const extraBtn = card.querySelector(".extra button");
    const addExtra = () => {{ if (extraInput.value.trim()) addLabels(r.id, extraInput.value); }};
    extraBtn.onclick = addExtra;
    extraInput.onkeydown = e => {{ if (e.key === "Enter") addExtra(); }};
    card.querySelector(".ok").onclick = () => {{
      entry(r.id).done = !entry(r.id).done;
      save(); render();
    }};
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
      id: r.id, path: r.path, seconds: r.seconds,
      labels: entry(r.id).labels, done: !!entry(r.id).done,
    }})),
  }};
}}
function downloadJSON() {{
  const blob = new Blob([JSON.stringify(payload(), null, 2)], {{type: "application/json"}});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "video_labels.json";
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


def do_run(args):
    if not args.root:
        sys.exit("请用 --root 或 LUMA_ORIGINALS 指定图库的 originals 目录")
    out_dir = args.out
    frames_dir = os.path.join(out_dir, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    videos = scan_videos(args.root)
    print(f"扫描到 {len(videos)} 条视频")
    picked = pick_videos(videos, args.limit, pool=args.pool)
    print(f"抽中 {len(picked)} 条（已按时长分层、跳过 <{MIN_SECONDS}s）")

    catalog = load_json(os.path.join(ROOT, TAGS))
    tags = catalog["tags"]
    frame_items = []
    items = []
    for index, (path, seconds) in enumerate(picked, start=1):
        vid = f"v{index:04d}"
        frame_names = []
        for frame_index, point in enumerate(FRAME_POINTS):
            name = f"{vid}_f{frame_index}.jpg"
            dest = os.path.join(frames_dir, name)
            if not os.path.exists(dest) and not extract_frame(path, seconds * point, dest):
                continue
            frame_names.append(name)
            frame_items.append({"id": f"{vid}_f{frame_index}", "path": dest})
        if len(frame_names) < 3:
            print(f"  {vid} 抽帧失败，跳过")
            continue
        items.append({
            "id": vid,
            "path": path,
            "seconds": round(seconds, 1),
            "frames": frame_names,
        })
        if index % 20 == 0:
            print(f"  抽帧 {index}/{len(picked)}")

    if not items:
        print("FAIL 没有可用视频")
        sys.exit(2)

    frame_goldset = os.path.join(out_dir, "frame_goldset.json")
    with open(frame_goldset, "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "items": frame_items}, handle, ensure_ascii=False)
    predictions_path = os.path.join(out_dir, "frame_predictions.json")
    print(f"逐帧预测 {len(frame_items)} 帧 …")
    result = subprocess.run(
        [PREDICTOR, frame_goldset, os.path.join(ROOT, TAGS), MODEL_DIR, predictions_path],
        capture_output=True, text=True)
    if result.returncode != 0:
        print("FAIL 逐帧预测失败：", result.stdout[-500:], result.stderr[-500:])
        sys.exit(2)
    print(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "预测完成")

    frame_pred = load_json(predictions_path)
    by_video = {}
    for item in frame_pred.get("items", []):
        vid = item["id"].split("_f")[0]
        by_video.setdefault(vid, []).append(item)

    video_predictions = []
    for row in items:
        frames = by_video.get(row["id"], [])
        scores, hits = aggregate_frames({"items": frames}, tags, len(row["frames"]))
        row["tags"] = sorted(hits, key=lambda title: -hits[title])
        video_predictions.append({"id": row["id"], "path": row["path"], "scores": scores})

    with open(os.path.join(out_dir, "items.json"), "w", encoding="utf-8") as handle:
        json.dump({"generatedAt": datetime.now().isoformat(timespec="seconds"),
                   "items": items}, handle, ensure_ascii=False, indent=2)
    with open(os.path.join(out_dir, "video_predictions.json"), "w", encoding="utf-8") as handle:
        json.dump({"generatedAt": datetime.now().isoformat(timespec="seconds"),
                   "note": "视频级分数取各帧最大分", "items": video_predictions},
                  handle, ensure_ascii=False)
    with open(os.path.join(out_dir, "video_goldset.json"), "w", encoding="utf-8") as handle:
        json.dump({
            "version": 1,
            "createdAt": datetime.now().isoformat(timespec="seconds"),
            "count": len(items),
            "items": [{"id": row["id"], "path": row["path"], "labels": [],
                       "seconds": row["seconds"]} for row in items],
        }, handle, ensure_ascii=False, indent=2)

    titles = sorted({tag["title"] for tag in tags})
    with open(os.path.join(out_dir, "review.html"), "w", encoding="utf-8") as handle:
        handle.write(build_html(items, titles, out_dir))

    zero = sum(1 for row in items if not row["tags"])
    print(f"\n视频金标 {len(items)} 条 → {out_dir}")
    print(f"模型聚合后 0 标签 {zero}/{len(items)}")
    print(f"核对页 {os.path.join(out_dir, 'review.html')}")


def main():
    parser = argparse.ArgumentParser(description="视频金标抽样 / 抽帧 / 预测 / 标注页")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--root", default=ORIGINALS,
                     help="图库 originals 目录；也可用环境变量 LUMA_ORIGINALS")
    run.add_argument("--limit", type=int, default=120)
    run.add_argument("--pool", type=int, default=1200,
                     help="先随机探时长的候选池大小")
    run.add_argument("--out", default="docs/ai/video-gold")
    run.set_defaults(func=do_run)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
