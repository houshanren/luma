#!/bin/zsh
# 用 Xcode 的 xctrace 给应用内界面基准录制 Instruments trace。
#
# 前置：
#   1. 安装完整 Xcode（App Store 或 developer.apple.com），并指向它：
#        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#        sudo xcodebuild -license accept
#   2. ./build.sh
#   3. 退出正在运行的 Luma（单实例应用）。
#
# 用法：
#   Tools/ui_trace.sh
#   Tools/ui_trace.sh --template "Time Profiler" --scenes grid-square,cinema-wall --seconds 6
#   Tools/ui_trace.sh --template "Animation Hitches" --output /tmp/luma-hitches.trace
#
# 产物：.trace（用 Instruments 打开）+ 同一目录下的 .json 聚合报告。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/Luma.app"
BINARY="${APP}/Contents/MacOS/Luma"
TEMPLATE="Animation Hitches"
SCENES="grid-square,grid-actual,grid-masonry,cinema-wall,catalog-channel"
SECONDS=5
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/luma-ui-trace-${STAMP}.trace"
REPORT="/tmp/luma-ui-trace-${STAMP}.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template) TEMPLATE="$2"; shift 2 ;;
        --scenes) SCENES="$2"; shift 2 ;;
        --seconds) SECONDS="$2"; shift 2 ;;
        --output) OUT="$2"; REPORT="${2%.trace}.json"; shift 2 ;;
        -h|--help)
            sed -n '1,22p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数：$1" >&2
            exit 2
            ;;
    esac
done

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find xctrace >/dev/null 2>&1; then
    cat >&2 <<'EOF'
没有找到 xctrace：需要完整 Xcode，而不是 Command Line Tools。

  1) 安装 Xcode（App Store 搜索 Xcode，或 https://developer.apple.com/download/all/）
  2) sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  3) sudo xcodebuild -license accept
  4) xcrun xctrace list templates   # 应能看到 Animation Hitches / Time Profiler

也可以用 xcodes CLI：brew install xcodes && xcodes signin && xcodes install --latest
EOF
    exit 2
fi

if [[ ! -x "$BINARY" ]]; then
    echo "找不到 $BINARY，请先 ./build.sh" >&2
    exit 2
fi
if pgrep -x Luma >/dev/null 2>&1; then
    echo "Luma 正在运行。请先退出，再运行 trace（应用是单实例）。" >&2
    exit 2
fi

# 两轮滚动 + 场景准备/切换的余量；上限 10 分钟，避免异常时一直录。
SCENE_COUNT="$(awk -F',' '{print NF}' <<<"$SCENES")"
LIMIT=$(( SCENE_COUNT * (SECONDS * 2 + 12) + 90 ))
(( LIMIT > 600 )) && LIMIT=600

rm -rf "$OUT" "$REPORT"
echo "录制模板：$TEMPLATE"
echo "场景：$SCENES  单轮：${SECONDS}s"
echo "trace：$OUT"
echo "报告：$REPORT"

xcrun xctrace record \
    --template "$TEMPLATE" \
    --time-limit "${LIMIT}s" \
    --output "$OUT" \
    --launch -- /usr/bin/env \
        "LUMA_UI_BENCH=${REPORT}" \
        "LUMA_UI_BENCH_SCENES=${SCENES}" \
        "LUMA_UI_BENCH_SECONDS=${SECONDS}" \
        "$BINARY"

echo
echo "trace 已生成：$OUT"
echo "打开：open \"$OUT\""
if [[ -f "$REPORT" ]]; then
    echo
    python3 "${ROOT}/Tools/ui_perf.py" --report "$REPORT"
else
    echo "没有生成聚合报告；请检查 ${REPORT} 与 ~/Library/Logs/Luma/diagnostics.log" >&2
fi
