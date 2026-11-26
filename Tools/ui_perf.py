#!/usr/bin/env python3
"""运行 Luma 的界面性能基准并汇总报告。

基准本身在 App 内执行：环境变量 `LUMA_UI_BENCH` 触发后，自动切换图库网格 /
影院海报墙 / 网络资源频道，滚动两轮并写出 JSON。本脚本只负责启动、等待与打印。

用法：
    python3 Tools/ui_perf.py
    python3 Tools/ui_perf.py --scenes grid-square,cinema-wall
    python3 Tools/ui_perf.py --seconds 8 --min-fps 55 --max-slow-ratio 0.05
    python3 Tools/ui_perf.py --build

注意：
- 需要先构建 `Luma.app`（`./build.sh`）；`--build` 会先执行一次完整构建。
- 运行前请退出已经打开的 Luma：应用是单实例，已有实例会让新进程直接退出。
- 网络资源场景依赖已启用的源，站点不可达时报告会标为 skipped。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / "Luma.app"
DEFAULT_SCENES = "grid-square,grid-actual,grid-masonry,cinema-wall,catalog-channel"
DEFAULT_LOG = Path.home() / "Library/Logs/Luma/diagnostics.log"


def luma_running() -> bool:
    try:
        result = subprocess.run(["pgrep", "-x", "Luma"], capture_output=True, text=True)
    except FileNotFoundError:
        return False
    return result.returncode == 0


def load_report(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def image_p95(pass_report: dict, key: str) -> float | None:
    for item in pass_report.get("imageLoads", []):
        if item.get("key") == key:
            return float(item.get("p95Ms", 0))
    return None


def fmt(value: float | None, digits: int = 1) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def print_report(report: dict) -> None:
    print(f"应用：{report.get('appVersion', '-')}  系统：{report.get('osVersion', '-')}  "
          f"架构：{report.get('architecture', '-')}")
    print(f"图库：{report.get('libraryPath', '-')}  可见照片：{report.get('libraryPhotoCount', 0)}")
    print()

    header = (f"{'场景':<16} {'轮次':<6} {'FPS':>6} {'p50':>7} {'p95':>7} {'p99':>7} "
              f"{'慢帧':>7} {'丢帧':>5} {'缩略/快速':>10} {'缩略/目标':>10} {'海报':>8}")
    print(header)
    print("-" * len(header))
    for scene in report.get("scenes", []):
        name = scene.get("scene", "-")
        status = scene.get("status")
        if status != "ok":
            note = scene.get("note") or ""
            print(f"{name:<16} {status:<6} {note}")
            continue
        for pass_report in scene.get("passes", []):
            frame = pass_report.get("frame", {})
            slow_ratio = float(frame.get("slowFrameRatio", 0)) * 100
            print(f"{name:<16} {frame.get('label', '-'):<6} "
                  f"{float(frame.get('fps', 0)):>6.1f} "
                  f"{float(frame.get('p50Ms', 0)):>6.1f} "
                  f"{float(frame.get('p95Ms', 0)):>6.1f} "
                  f"{float(frame.get('p99Ms', 0)):>6.1f} "
                  f"{slow_ratio:>6.1f}% "
                  f"{int(frame.get('estimatedDroppedFrames', 0)):>5} "
                  f"{fmt(image_p95(pass_report, 'grid.quick')):>9} "
                  f"{fmt(image_p95(pass_report, 'grid.target')):>9} "
                  f"{fmt(image_p95(pass_report, 'poster.poster')):>7}")
    print()
    print("说明：FPS / 分位基于 CADisplayLink 采样；缩略/快速、缩略/目标、海报为 p95 毫秒。")
    print("      慢帧 = 超过 1.5 帧间隔（或 24ms）的帧；丢帧按间隔折算。")


def check_thresholds(report: dict, min_fps: float | None,
                     max_slow_ratio: float | None) -> list[str]:
    problems: list[str] = []
    for scene in report.get("scenes", []):
        if scene.get("status") != "ok":
            continue
        for pass_report in scene.get("passes", []):
            frame = pass_report.get("frame", {})
            label = f"{scene.get('scene')}/{frame.get('label')}"
            fps = float(frame.get("fps", 0))
            slow = float(frame.get("slowFrameRatio", 0))
            if min_fps is not None and fps < min_fps:
                problems.append(f"{label} FPS {fps:.1f} < {min_fps:.1f}")
            if max_slow_ratio is not None and slow > max_slow_ratio:
                problems.append(f"{label} 慢帧比例 {slow * 100:.1f}% > {max_slow_ratio * 100:.1f}%")
    return problems


def tail_log(lines: int = 30) -> str:
    if not DEFAULT_LOG.exists():
        return "（没有诊断日志）"
    try:
        content = DEFAULT_LOG.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "（诊断日志读取失败）"
    return "\n".join(content[-lines:])


def main() -> int:
    parser = argparse.ArgumentParser(description="运行 Luma 界面性能基准")
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--scenes", default=DEFAULT_SCENES)
    parser.add_argument("--seconds", type=float, default=5.0, help="单轮滚动时长")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--report", type=Path, default=None,
                        help="只解析已有报告（例如 ui_trace.sh 生成的 JSON）")
    parser.add_argument("--timeout", type=float, default=360.0)
    parser.add_argument("--build", action="store_true", help="启动前执行 ./build.sh")
    parser.add_argument("--min-fps", type=float, default=None)
    parser.add_argument("--max-slow-ratio", type=float, default=None,
                        help="慢帧比例上限，例如 0.05")
    parser.add_argument("--allow-running", action="store_true",
                        help="允许已有 Luma 实例存在（通常新进程会直接退出）")
    args = parser.parse_args()

    if args.report is not None:
        if not args.report.exists():
            print(f"找不到报告：{args.report}", file=sys.stderr)
            return 2
        report = load_report(args.report)
        print_report(report)
        problems = check_thresholds(report, args.min_fps, args.max_slow_ratio)
        if problems:
            print("\n阈值未通过：")
            for problem in problems:
                print(f"  ✗ {problem}")
            return 1
        if args.min_fps is not None or args.max_slow_ratio is not None:
            print("\n阈值通过。")
        return 0

    binary = args.app / "Contents/MacOS/Luma"
    if args.build:
        print("构建 Luma.app…")
        subprocess.run([str(ROOT / "build.sh")], cwd=ROOT, check=True)
    if not binary.exists():
        print(f"找不到可执行文件：{binary}\n先运行 ./build.sh，或加 --build。", file=sys.stderr)
        return 2
    if luma_running() and not args.allow_running:
        print("Luma 已经在运行。应用是单实例，新进程会直接退出。\n"
              "请先退出 Luma，再重新运行本脚本。", file=sys.stderr)
        return 2

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = args.out or Path(f"/tmp/luma-ui-perf-{stamp}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    env = os.environ.copy()
    env["LUMA_UI_BENCH"] = str(out)
    env["LUMA_UI_BENCH_SCENES"] = args.scenes
    env["LUMA_UI_BENCH_SECONDS"] = str(args.seconds)

    print(f"启动基准：scenes={args.scenes} 单轮={args.seconds:g}s 输出={out}")
    process = subprocess.Popen([str(binary)], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + args.timeout
    last_notice = time.time()
    try:
        while time.time() < deadline:
            if out.exists():
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.terminate()
                break
            if process.poll() is not None:
                print(f"应用已退出（exit={process.returncode}），但没有生成报告。", file=sys.stderr)
                break
            if time.time() - last_notice > 15:
                last_notice = time.time()
                print("等待基准完成…（应用窗口会自动切换场景并滚动）", flush=True)
            time.sleep(0.5)
        else:
            print("基准超时，终止应用。", file=sys.stderr)
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    finally:
        if process.poll() is None:
            process.terminate()

    if not out.exists():
        print("没有生成报告。诊断日志末尾：", file=sys.stderr)
        print(tail_log(), file=sys.stderr)
        return 1

    report = load_report(out)
    print_report(report)
    problems = check_thresholds(report, args.min_fps, args.max_slow_ratio)
    if problems:
        print("\n阈值未通过：")
        for problem in problems:
            print(f"  ✗ {problem}")
        return 1
    if args.min_fps is not None or args.max_slow_ratio is not None:
        print("\n阈值通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
