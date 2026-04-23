#!/usr/bin/env bash
# scripts/build_hotzones.sh
# 一气呵成生成指定楼栋/楼层的"热区图"（.svg + floor_map.json），
# 对标 Flutter 应用中 ViewerScreen 的"热区图导出"按钮。
#
# 流水线（参考 build_floors.sh 的风格）：
#   1. （可选）DWG → DXF：cad_source/<building>/*.dwg → cad_intermediate/<building>/*.dxf
#      - 若 DXF 已存在且比 DWG 新则跳过此步（除非 --force）
#   2. DXF → 热区 SVG + floor_map JSON：
#        cad_intermediate/<building>/<file>.dxf
#        → cad_intermediate/<building>/hotzones/<prefix>_hotspot.svg
#        → cad_intermediate/<building>/hotzones/<prefix>_hotspot.json
#
# 用法:
#   bash scripts/build_hotzones.sh <building> --boundary-layer <name> \
#        [--dxf <file>] [--prefix <name>] [--layout <layout>] \
#        [--label-layers "L1,L2"] [--status vacant] \
#        [--floor-id <uuid>] [--building-id <uuid>] \
#        [--force] [--skip-dwg] [--list-layers] [--list-layouts]
#
# 参数:
#   <building>         楼栋目录名，必填（例如 building_a）
#   --boundary-layer   边界图层名（闭合多段线 = 单元），除非 --list-*，否则必填
#   --dxf <file>       指定 DXF 文件名（相对 cad_intermediate/<building>/）；
#                      默认自动选第一个非"配电/照明/暖通/结构"等次要图纸
#   --prefix <name>    输出文件名前缀，默认从 DXF 文件名推断
#   --layout <name>    ezdxf 布局名，默认 "Model"
#   --label-layers     文字图层名（逗号分隔），用于自动匹配 unit_number，可省略
#   --status <name>    初始状态 class，默认 vacant
#                      可选：vacant/leased/expiring-soon/renovating/non-leasable
#   --floor-id <uuid>  写入 JSON 的 floor_id，省略则自动生成
#   --building-id <u>  写入 JSON 的 building_id，省略则自动生成
#   --force            即使 DXF 是最新的也重转 DWG
#   --skip-dwg         跳过 DWG→DXF 步骤
#   --list-layers      仅列出 DXF 图层统计（按闭合形状评分）后退出
#   --list-layouts     仅列出 DXF 布局后退出
#
# 示例:
#   # 先看图层，选出边界图层
#   bash scripts/build_hotzones.sh building_a --list-layers
#
#   # 正式导出（边界图层叫 SPACE，文字图层叫 房号）
#   bash scripts/build_hotzones.sh building_a \
#        --boundary-layer SPACE --label-layers 房号 \
#        --prefix A座_1F --status vacant

set -euo pipefail

# --- 参数解析 ---
BUILDING="${1:-}"
if [[ -z "$BUILDING" || "$BUILDING" == "-h" || "$BUILDING" == "--help" ]]; then
  sed -n '2,45p' "$0"
  exit 1
fi
shift

DXF_NAME=""
PREFIX=""
LAYOUT="Model"
BOUNDARY_LAYER=""
LABEL_LAYERS=""
STATUS="vacant"
FLOOR_ID=""
BUILDING_ID=""
FORCE=0
SKIP_DWG=0
LIST_LAYERS=0
LIST_LAYOUTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dxf)              DXF_NAME="$2"; shift 2 ;;
    --prefix)           PREFIX="$2"; shift 2 ;;
    --layout)           LAYOUT="$2"; shift 2 ;;
    --boundary-layer)   BOUNDARY_LAYER="$2"; shift 2 ;;
    --label-layers)     LABEL_LAYERS="$2"; shift 2 ;;
    --status)           STATUS="$2"; shift 2 ;;
    --floor-id)         FLOOR_ID="$2"; shift 2 ;;
    --building-id)      BUILDING_ID="$2"; shift 2 ;;
    --force)            FORCE=1; shift ;;
    --skip-dwg)         SKIP_DWG=1; shift ;;
    --list-layers)      LIST_LAYERS=1; shift ;;
    --list-layouts)     LIST_LAYOUTS=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# --- 路径 ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC_DIR="cad_source/${BUILDING}"
OUT_DIR="cad_intermediate/${BUILDING}"
HOTZONES_DIR="${OUT_DIR}/hotzones"
SCRIPT="scripts/annotate_hotzones.py"
VENV_ACTIVATE="${ROOT}/.venv/bin/activate"

# --- Python venv 激活 ---
if [[ -f "$VENV_ACTIVATE" ]]; then
  # shellcheck disable=SC1090
  source "$VENV_ACTIVATE"
fi

# --- Step 1: DWG → DXF（和 build_floors.sh 保持一致）---
if [[ "$SKIP_DWG" -eq 0 && -d "$SRC_DIR" ]]; then
  NEED_CONVERT=0
  DWGS=()
  while IFS= read -r -d '' f; do DWGS+=("$f"); done \
    < <(find "$SRC_DIR" -maxdepth 1 \( -name "*.dwg" -o -name "*.DWG" \) -print0 2>/dev/null || true)

  if [[ ${#DWGS[@]} -gt 0 ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      NEED_CONVERT=1
    else
      for dwg in "${DWGS[@]}"; do
        base="$(basename "$dwg")"
        dxf="${OUT_DIR}/${base%.*}.dxf"
        if [[ ! -f "$dxf" || "$dwg" -nt "$dxf" ]]; then
          NEED_CONVERT=1
          break
        fi
      done
    fi

    if [[ "$NEED_CONVERT" -eq 1 ]]; then
      echo "=== [1/2] DWG → DXF ==="
      bash scripts/cad_to_dxf.sh "$BUILDING"
    else
      echo "=== [1/2] DWG → DXF  (跳过：DXF 已是最新) ==="
    fi
  else
    echo "=== [1/2] DWG → DXF  (跳过：$SRC_DIR 无 DWG) ==="
  fi
else
  echo "=== [1/2] DWG → DXF  (跳过) ==="
fi

# --- 选择 DXF ---
if [[ ! -d "$OUT_DIR" ]]; then
  echo "错误: DXF 目录不存在 — $OUT_DIR" >&2
  exit 1
fi

if [[ -z "$DXF_NAME" ]]; then
  DXF_NAME="$(
    find "$OUT_DIR" -maxdepth 1 -name "*.dxf" -print \
      | grep -Ev "配电|照明|给排水|暖通|电气|消防|结构|节点|详图" \
      | head -n 1 \
      | xargs -I {} basename {} \
      || true
  )"
  if [[ -z "$DXF_NAME" ]]; then
    DXF_NAME="$(find "$OUT_DIR" -maxdepth 1 -name "*.dxf" -print | head -n 1 | xargs -I {} basename {})"
  fi
fi

DXF_PATH="${OUT_DIR}/${DXF_NAME}"
if [[ ! -f "$DXF_PATH" ]]; then
  echo "错误: DXF 文件不存在 — $DXF_PATH" >&2
  exit 1
fi

if [[ -z "$PREFIX" ]]; then
  PREFIX="${DXF_NAME%.*}"
fi

# --- list-* 模式：直接透传给 annotate_hotzones.py ---
if [[ "$LIST_LAYOUTS" -eq 1 ]]; then
  python3 "$SCRIPT" "$DXF_PATH" --list-layouts
  exit 0
fi
if [[ "$LIST_LAYERS" -eq 1 ]]; then
  python3 "$SCRIPT" "$DXF_PATH" --list-layers --layout "$LAYOUT"
  exit 0
fi

# --- 正式导出必需参数校验 ---
if [[ -z "$BOUNDARY_LAYER" ]]; then
  echo "错误: 必须指定 --boundary-layer（或用 --list-layers 先查）" >&2
  exit 1
fi

# --- Step 2: DXF → 热区 SVG + JSON ---
echo ""
echo "=== [2/2] DXF → 热区 SVG + floor_map JSON ==="
echo "输入    : $DXF_PATH  (layout=$LAYOUT)"
echo "边界层  : $BOUNDARY_LAYER"
[[ -n "$LABEL_LAYERS" ]] && echo "文字层  : $LABEL_LAYERS"
echo "状态    : $STATUS"
echo ""

mkdir -p "$HOTZONES_DIR"
OUT_SVG="${HOTZONES_DIR}/${PREFIX}_hotspot.svg"
OUT_JSON="${HOTZONES_DIR}/${PREFIX}_hotspot.json"

# 清掉旧产物
rm -f "$OUT_SVG" "$OUT_JSON"

CMD=(python3 "$SCRIPT" "$DXF_PATH"
     --layout "$LAYOUT"
     --boundary-layer "$BOUNDARY_LAYER"
     --status "$STATUS"
     --out-svg "$OUT_SVG"
     --out-json "$OUT_JSON")
[[ -n "$LABEL_LAYERS" ]] && CMD+=(--label-layers "$LABEL_LAYERS")
[[ -n "$FLOOR_ID"    ]] && CMD+=(--floor-id "$FLOOR_ID")
[[ -n "$BUILDING_ID" ]] && CMD+=(--building-id "$BUILDING_ID")

"${CMD[@]}" 2>&1 | grep -v "DIMASSOC" || true

if [[ ! -f "$OUT_SVG" || ! -f "$OUT_JSON" ]]; then
  echo "错误: 导出未产生 SVG/JSON，请检查上方日志" >&2
  exit 1
fi

echo ""
echo "================================================"
echo "全部完成"
echo "  SVG  : $OUT_SVG"
echo "  JSON : $OUT_JSON"
echo "================================================"
