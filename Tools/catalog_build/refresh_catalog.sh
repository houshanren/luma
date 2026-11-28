#!/usr/bin/env bash
# 一键构建 catalog.sqlite：抓取（可选）→ 本地归一 → R18 导出 → 建库 → 头像（可选）→ 打包（可选）
#
# 用法：
#   Tools/catalog_build/refresh_catalog.sh                 # 离线：用现有 raw 归一 + 重建库（约 10 分钟）
#   Tools/catalog_build/refresh_catalog.sh --fetch         # 先联网刷新全部一手源（很慢，单步失败自动跳过）
#   Tools/catalog_build/refresh_catalog.sh --skip-derive   # 跳过本地归一，只跑 R18 导出 + 建库
#   Tools/catalog_build/refresh_catalog.sh --skip-r18      # 跳过 R18，只做归一 + 建库
#   Tools/catalog_build/refresh_catalog.sh --refresh       # R18 强制重新解析 dump（约 5–10 分钟）
#   Tools/catalog_build/refresh_catalog.sh --refresh --dump 路径
#   Tools/catalog_build/refresh_catalog.sh --existing-only # 只补已有女优，不给 R18 新人建档
#   Tools/catalog_build/refresh_catalog.sh --avatars       # 重建后补头像，再重建一次
#   Tools/catalog_build/refresh_catalog.sh --app           # 最后跑 ./build.sh debug 出包
#   Tools/catalog_build/refresh_catalog.sh --strict        # 任一步失败立即退出（默认尽量继续）
#
# 日志：raw/.pipeline_derive.log / .pipeline_r18.log / .pipeline_build.log /
#       .pipeline_avatars.log / .pipeline_app.log / .pipeline_fetch_*.log
# 默认非严格模式：某一步失败不会丢现有数据，能继续的步骤继续跑，最后汇总退出码。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="Tools/catalog_build/raw"
mkdir -p "$LOG_DIR"
PY="python3"

FETCH=""
SKIP_DERIVE=""
SKIP_R18=""
BUILD_APP=""
STRICT=""
WITH_AVATARS=""
DUMP=""
R18_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) FETCH="1"; shift ;;
    --skip-derive) SKIP_DERIVE="1"; shift ;;
    --refresh) R18_ARGS+=("--refresh"); shift ;;
    --skip-r18) SKIP_R18="1"; shift ;;
    --existing-only) R18_ARGS+=("--existing-only"); shift ;;
    --avatars) WITH_AVATARS="1"; shift ;;
    --app) BUILD_APP="1"; shift ;;
    --strict) STRICT="1"; shift ;;
    --dump)
      shift
      if [ -z "${1:-}" ]; then
        echo "--dump 需要紧跟一个 dump 文件路径" >&2
        exit 2
      fi
      DUMP="$1"
      R18_ARGS+=("--dump" "$DUMP")
      shift
      ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

status=0
fail() {
  echo "[失败] $1，详见 $2"
  status=1
  if [ -n "$STRICT" ]; then
    echo "严格模式：中断。"
    exit 1
  fi
}

# 跑一个抓取步骤：日志单独一份，失败只记警告（除非 --strict）。
fetch_step() {
  local label="$1"; shift
  echo "   $label"
  if "$@" >> "$LOG_DIR/.pipeline_fetch_${label}.log" 2>&1; then
    return 0
  fi
  fail "抓取 $label" "$LOG_DIR/.pipeline_fetch_${label}.log"
}

# 跑一个本地归一步骤：共用一份日志。
derive_step() {
  local label="$1"; shift
  echo "   $label"
  { echo "=== $label ==="; "$@"; } >> "$LOG_DIR/.pipeline_derive.log" 2>&1
  if [ $? -ne 0 ]; then
    fail "归一 $label" "$LOG_DIR/.pipeline_derive.log"
  fi
}

if [ -n "$FETCH" ]; then
  echo "== 联网抓取一手源（单步失败不会中断）"
  fetch_step wiki_bios $PY Tools/catalog_build/fetch/fetch_wiki_bios.py
  fetch_step ja_wiki $PY Tools/catalog_build/fetch/fetch_ja_wiki.py
  fetch_step jav_index $PY Tools/catalog_build/fetch/fetch_jav_index.py
  fetch_step javbus_lists $PY Tools/catalog_build/fetch/fetch_javbus.py lists
  fetch_step javbus_details $PY Tools/catalog_build/fetch/fetch_javbus.py details
  fetch_step javrate_details $PY Tools/catalog_build/fetch/fetch_javrate_details.py
  fetch_step kkkhai $PY Tools/catalog_build/fetch/fetch_kkkhai_site.py
  fetch_step coscd $PY Tools/catalog_build/fetch/fetch_coscd.py
  fetch_step mms $PY Tools/catalog_build/fetch/fetch_mms.py
  fetch_step cn_profiles $PY Tools/catalog_build/fetch/fetch_cn_profiles.py
  fetch_step cn_profiles_more $PY Tools/catalog_build/fetch/fetch_cn_profiles_more.py
  fetch_step cn_profiles_extra $PY Tools/catalog_build/fetch/fetch_cn_profiles_extra.py
  fetch_step cn_profiles_r7 $PY Tools/catalog_build/fetch/fetch_cn_profiles_round7.py
  fetch_step cn_profiles_r8 $PY Tools/catalog_build/fetch/fetch_cn_profiles_round8.py
  fetch_step cn_round10 $PY Tools/catalog_build/fetch/fetch_cn_round10.py
  fetch_step xiurenwang $PY Tools/catalog_build/fetch/fetch_xiurenwang.py
  fetch_step xiurenz $PY Tools/catalog_build/fetch/fetch_xiurenz.py
  fetch_step xsnvshen $PY Tools/catalog_build/fetch/fetch_xsnvshen.py
  fetch_step xsnvshen_covers $PY Tools/catalog_build/fetch/fetch_xsnvshen_covers.py
  fetch_step cn_contacts $PY Tools/catalog_build/fetch/fetch_cn_contacts.py
  fetch_step wikidata $PY Tools/catalog_build/fetch/fetch_wikidata_performers.py
  fetch_step graphis $PY Tools/catalog_build/fetch/fetch_graphis.py
  fetch_step studio_logos $PY Tools/catalog_build/fetch/fetch_studio_logo_images.py --mousou --xiuren
fi

if [ -z "$SKIP_DERIVE" ]; then
  echo "== 本地归一（raw → raw，不联网）"
  : > "$LOG_DIR/.pipeline_derive.log"
  derive_step coscd_people $PY Tools/catalog_build/build/build_coscd_people.py
  derive_step coscd_details $PY Tools/catalog_build/build/build_coscd_details.py
  derive_step kkkhai_brands $PY Tools/catalog_build/build/build_kkkhai_brands.py
  derive_step kkkhai_tags $PY Tools/catalog_build/build/build_kkkhai_tags.py
  derive_step kkkhai_details $PY Tools/catalog_build/build/build_kkkhai_details.py
  derive_step mms_people $PY Tools/catalog_build/build/build_mms_people.py
  derive_step mms_contacts $PY Tools/catalog_build/build/build_mms_contacts.py
  derive_step extra_names $PY Tools/catalog_build/build/build_extra_names.py
  derive_step javbus_map $PY Tools/catalog_build/build/build_javbus_map.py
  derive_step xsnvshen_region $PY Tools/catalog_build/build/fix_xsnvshen_region.py
  # 从 App 里已接入站点的分类 / 标签反哺星图：产出 raw/site_people.json、raw/site_studios.json。
  # 只读 App 图库的 catalog_kv，不联网；站点还没点开过时产出为空，不影响建库。
  derive_step site_taxonomy $PY Tools/catalog_build/import/extract_site_taxonomy.py
fi

if [ -z "$SKIP_R18" ]; then
  echo "== R18 dump → raw/r18_actresses.json + raw/r18_videos.json"
  if $PY Tools/catalog_build/import/import_r18_dump.py ${R18_ARGS[@]+"${R18_ARGS[@]}"} \
      > "$LOG_DIR/.pipeline_r18.log" 2>&1; then
    grep -E '缓存完成|匹配到|R18 新人档案|作品总数|DMM 演员 ID 映射|写出' \
      "$LOG_DIR/.pipeline_r18.log" | tail -8
  else
    fail "R18 导出" "$LOG_DIR/.pipeline_r18.log"
    echo "   继续用现有 raw/r18_*.json 重建（加 --strict 可中断）"
  fi
fi

build_database() {
  local log="${1:-$LOG_DIR/.pipeline_build.log}"
  if $PY Tools/catalog_build/build/build_catalog_db.py > "$log" 2>&1; then
    tail -9 "$log"
    return 0
  fi
  fail "建库" "$log"
  return 1
}

CATALOG_DB="${LUMA_CATALOG_DB:-$HOME/Downloads/catalog.sqlite}"
echo "== 重建 ${CATALOG_DB}"
build_database "$LOG_DIR/.pipeline_build.log" || exit 1

if [ -n "$WITH_AVATARS" ]; then
  echo "== 下载缺的头像（raw/avatar_images.json 增量）"
  # fetch_avatars 默认走 8118 代理；代理没开时直连（DMM 图床直连可通），
  # 否则每张图要等三次超时，2 万张会拖成几小时。
  if [ -z "${MONO_PROXY+x}" ] && command -v nc >/dev/null 2>&1 \
      && ! nc -z 127.0.0.1 8118 >/dev/null 2>&1; then
    export MONO_PROXY=""
    echo "   本机 8118 代理未开，头像改直连"
  fi
  if $PY Tools/catalog_build/fetch/fetch_avatars.py > "$LOG_DIR/.pipeline_avatars.log" 2>&1; then
    tail -3 "$LOG_DIR/.pipeline_avatars.log"
    echo "== 头像写入后再重建一次"
    build_database "$LOG_DIR/.pipeline_build2.log" || exit 1
  else
    fail "头像下载" "$LOG_DIR/.pipeline_avatars.log"
  fi
fi

if [ -n "$BUILD_APP" ]; then
  echo "== 打包 Luma.app"
  # 上一次签名会把 Resources/lib 里的 dylib 变成只读，cp 会 Permission denied。
  chmod -R u+w Luma.app/Contents/Resources/lib 2>/dev/null || true
  if ./build.sh debug > "$LOG_DIR/.pipeline_app.log" 2>&1; then
    tail -3 "$LOG_DIR/.pipeline_app.log"
  else
    fail "打包" "$LOG_DIR/.pipeline_app.log"
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "完成。"
else
  echo "有步骤失败（见上面日志路径），其余步骤已尽量执行。"
fi
exit "$status"
