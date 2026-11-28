#!/usr/bin/env python3
"""同一批照片上横向对比本地 Qwen 视觉模型（Ollama /api/chat）。

目的：用同一提示词、同一批真实照片，比较 Qwen2.5-VL 3B 与更新一代 Qwen3-VL 的
JSON 合法率、延迟与事件字段质量，结论写回 docs/ai/vision-understanding-benchmark-2026-11.md。

用法：
  python3 Tools/vision_bench/qwen_compare.py --limit 12 \
    --models luma-qwen2.5vl:3b luma-qwen3vl:8b \
    --out docs/ai/goldset-40/qwen_compare.json
"""

import argparse
import base64
import json
import os
import subprocess
import time
import urllib.request

ENDPOINT = "http://127.0.0.1:11434/api/chat"

PROMPT = (
    "你只做一件事：看这张照片，输出一个 JSON 对象，不要任何解释文字。\n"
    "字段：\n"
    "- activity：照片里正在发生的事，6 个汉字以内；看不到人就写场景，例如「湖边散步」\n"
    "- participants：画面里有哪些人，例如「无人」「一名成年男性」「两名儿童」「一家人」\n"
    "- setting：拍摄地点类型，例如「餐厅」「海滩」「客厅」「街道」\n"
    "- mood：整体氛围，两个词以内\n"
    "- confidence：0 到 1 的数字，表示你对 activity 判断的把握\n"
    "只根据画面可见内容，不要猜测人物身份或关系。"
)

KEYS = ["activity", "participants", "setting", "mood", "confidence"]


def run_import(path):
    with open(path, "rb") as handle:
        return base64.b64encode(handle.read()).decode()


def chat(model, image_b64, timeout=300, ctx=16384, max_predict=256):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT, "images": [image_b64]}],
        "format": "json",
        "stream": False,
        "options": {"temperature": 0.2, "num_predict": max_predict, "num_ctx": ctx},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read().decode())
    elapsed = time.monotonic() - started
    content = (body.get("message") or {}).get("content", "")
    try:
        parsed = json.loads(content)
        valid = True
    except Exception:
        parsed, valid = None, False
    return {
        "content": content,
        "json": parsed,
        "valid": valid,
        "seconds": round(elapsed, 2),
        "evalCount": body.get("eval_count"),
        "promptEvalCount": body.get("prompt_eval_count"),
    }


def runner_rss_gb():
    """当前 ollama llama-server 进程的最大 RSS（GB）。统一内存下这是宿主侧占用。"""
    out = subprocess.run(["ps", "-Ao", "rss,command"], capture_output=True, text=True).stdout
    best = 0
    for line in out.splitlines():
        if "ollama" not in line:
            continue
        if "runner" not in line and "llama-server" not in line:
            continue
        try:
            best = max(best, int(line.split()[0]))
        except ValueError:
            continue
    return round(best / 1024 / 1024, 2)


def loaded_model_gb(model):
    """Ollama 报告的已加载模型体积（含 KV cache），失败返回 0。"""
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=5) as response:
            data = json.loads(response.read().decode())
        for item in data.get("models", []):
            if item.get("name") == model:
                return round(item.get("size", 0) / 1e9, 2)
    except Exception:
        pass
    return 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--images-dir", default="docs/ai/goldset-40/images")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--models", nargs="+",
                        default=["luma-qwen2.5vl:3b", "luma-qwen3vl:8b"])
    parser.add_argument("--out", default="docs/ai/goldset-40/qwen_compare.json")
    parser.add_argument("--ctx", type=int, default=16384)
    parser.add_argument("--max-predict", type=int, default=256)
    args = parser.parse_args()

    files = sorted(f for f in os.listdir(args.images_dir) if f.endswith(".jpg"))[: args.limit]
    print(f"样本 {len(files)} 张：{', '.join(files)}")

    report = {"endpoint": ENDPOINT, "prompt": PROMPT, "images": files, "models": {}}

    for model in args.models:
        print(f"\n=== {model} ===")
        results = []
        peak_rss = 0.0
        loaded = 0.0
        for index, name in enumerate(files, start=1):
            path = os.path.join(args.images_dir, name)
            try:
                item = chat(model, run_import(path),
                            ctx=args.ctx, max_predict=args.max_predict)
            except Exception as error:  # 单个样本失败不中断整批
                item = {"content": "", "json": None, "valid": False,
                        "seconds": 0.0, "evalCount": None,
                        "promptEvalCount": None, "error": str(error)}
            peak_rss = max(peak_rss, runner_rss_gb())
            loaded = max(loaded, loaded_model_gb(model))
            results.append({"image": name, **item})
            status = "OK" if item["valid"] else "BAD"
            print(f"  [{index}/{len(files)}] {name} {item['seconds']}s {status} "
                  f"rss={peak_rss}GB")
            if item.get("error"):
                print(f"      error: {item['error'][:120]}")
            if item["valid"]:
                print(f"      {json.dumps(item['json'], ensure_ascii=False)}")

        valid = sum(1 for r in results if r["valid"])
        times = [r["seconds"] for r in results if r["valid"] and r["seconds"] > 0]
        if not times:
            times = [0.0]
        warm = times[1:] or times
        missing = {}
        for result in results:
            if not result["valid"]:
                continue
            for key in KEYS:
                if key not in result["json"]:
                    missing[key] = missing.get(key, 0) + 1
        report["models"][model] = {
            "images": len(results),
            "jsonValid": valid,
            "medianSeconds": round(sorted(warm)[len(warm) // 2], 2),
            "maxSeconds": max(times),
            "firstSeconds": times[0],
            "peakRunnerRSSGB": peak_rss,
            "loadedSizeGB": loaded,
            "missingKeys": missing,
            "results": results,
        }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)

    print("\n=== 汇总 ===")
    print(f"{'模型':<22}{'JSON':>8}{'中位':>9}{'最慢':>9}{'首张':>9}{'占用':>8}")
    for model, stats in report["models"].items():
        print(f"{model:<22}{stats['jsonValid']}/{stats['images']:>4}"
              f"{stats['medianSeconds']:>8}s{stats['maxSeconds']:>8}s"
              f"{stats['firstSeconds']:>8}s{stats['loadedSizeGB']:>7}G")
    print(f"\n写入 {args.out}")


if __name__ == "__main__":
    main()
