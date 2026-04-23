#!/usr/bin/env bash
# scripts/build_floors.sh
# 一气呵成生成指定楼栋的全部楼层 SVG（可选同时出 PNG 预览）
#
# 流水线：
#   1. （可选）DWG → DXF：cad_source/<building>/*.dwg → cad_intermediate/<building>/*.dxf
#      - 若 DXF 已存在且比 DWG 新则跳过此步（除非 --force）
#   2. DXF → 多个 SVG：cad_intermediate/<building>/<name>.dxf
#      → cad_intermediate/<building>/floors/<prefix>_*.svg
#   3. （可选）SVG → PNG 预览：cad_intermediate/<building>/floors/preview/*.png
#
# 用法:
#   bash scripts/build_floors.sh <building> [--dxf <file>] [--prefix <name>]
#                                [--png] [--png-width N] [--force] [--skip-dwg]
#
# 参数:
#   <building>        楼栋目录名，必填（例如 building_a）
#   --dxf <file>      指定要切分的 DXF 文件名（相对 cad_intermediate/<building>/）
#                     默认：自动选第一个 .dxf
#   --prefix <name>   输出 SVG 文件名前缀，默认从 DXF 文件名推断
#   --png             同时生成 PNG 预览（需要 rsvg-convert）
#   --png-width N     PNG 宽度像素，默认 2000
#   --force           即使 DXF 是最新的也重转 DWG
#   --skip-dwg        跳过 DWG→DXF 步骤，直接用现有 DXF
#
# 示例:
#   bash scripts/build_floors.sh building_a
#   bash scripts/build_floors.sh building_a --png
#   bash scripts/build_floors.sh building_a --dxf "A座.dxf" --prefix A座 --png

set -euo pipefail

# --- 参数解析 ---
BUILDING="${1:-}"
if [[ -z "$BUILDING" || "$BUILDING" == "-h" || "$BUILDING" == "--help" ]]; then
  sed -n '2,30p' "$0"
  exit 1
fi
shift

DXF_NAME=""
PREFIX=""
GEN_PNG=0
PNG_WIDTH=2000
FORCE=0
SKIP_DWG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dxf)       DXF_NAME="$2"; shift 2 ;;
    --prefix)    PREFIX="$2"; shift 2 ;;
    --png)       GEN_PNG=1; shift ;;
    --png-width) PNG_WIDTH="$2"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    --skip-dwg)  SKIP_DWG=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# --- 路径 ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC_DIR="cad_source/${BUILDING}"
OUT_DIR="cad_intermediate/${BUILDING}"
FLOORS_DIR="${OUT_DIR}/floors"
PREVIEW_DIR="${FLOORS_DIR}/preview"
SPLIT_SCRIPT="scripts/split_dxf_by_floor.py"
VENV_ACTIVATE="${ROOT}/.venv/bin/activate"

# --- Python venv 激活 ---
if [[ -f "$VENV_ACTIVATE" ]]; then
  # shellcheck disable=SC1090
  source "$VENV_ACTIVATE"
fi

# --- Step 1: DWG → DXF ---
if [[ "$SKIP_DWG" -eq 0 && -d "$SRC_DIR" ]]; then
  # 找最新的 DWG；若存在、且对应 DXF 更旧（或不存在）则重转
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
      echo "=== [1/3] DWG → DXF ==="
      bash scripts/cad_to_dxf.sh "$BUILDING"
    else
      echo "=== [1/3] DWG → DXF  (跳过：DXF 已是最新) ==="
    fi
  else
    echo "=== [1/3] DWG → DXF  (跳过：$SRC_DIR 无 DWG) ==="
  fi
else
  echo "=== [1/3] DWG → DXF  (跳过) ==="
fi

# --- Step 2: 选择 DXF 并切分 ---
if [[ ! -d "$OUT_DIR" ]]; then
  echo "错误: DXF 目录不存在 — $OUT_DIR" >&2
  exit 1
fi

if [[ -z "$DXF_NAME" ]]; then
  # 自动挑选：取文件名不包含"配电"/"照明"/"给排水"/"暖通"等次要图纸关键字的第一个 DXF
  DXF_NAME="$(
    find "$OUT_DIR" -maxdepth 1 -name "*.dxf" -print \
      | grep -Ev "配电|照明|给排水|暖通|电气|消防|结构|节点|详图" \
      | head -n 1 \
      | xargs -I {} basename {} \
      || true
  )"
  if [[ -z "$DXF_NAME" ]]; then
    # 兜底：取任意第一个
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

echo ""
echo "=== [2/3] DXF → SVG 切分 ==="
echo "输入  : $DXF_PATH"
echo "输出  : $FLOORS_DIR/${PREFIX}_*.svg"
echo ""

mkdir -p "$FLOORS_DIR"
# 清空旧的同前缀 SVG（避免上次残留）
find "$FLOORS_DIR" -maxdepth 1 -name "${PREFIX}_*.svg" -delete 2>/dev/null || true

# 跑切分脚本（过滤 DIMASSOC 噪音日志）
python3 "$SPLIT_SCRIPT" "$DXF_PATH" "$FLOORS_DIR" --prefix "$PREFIX" 2>&1 \
  | grep -v "DIMASSOC" \
  || true

SVG_COUNT=$(find "$FLOORS_DIR" -maxdepth 1 -name "${PREFIX}_*.svg" | wc -l | tr -d ' ')
if [[ "$SVG_COUNT" -eq 0 ]]; then
  echo "错误: 未生成任何 SVG" >&2
  exit 1
fi
echo ""
echo "=== 切分完成: 生成 ${SVG_COUNT} 个 SVG ==="

# --- Step 3: PNG 预览 ---
if [[ "$GEN_PNG" -eq 1 ]]; then
  echo ""
  echo "=== [3/3] SVG → PNG 预览 ==="

  if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "警告: rsvg-convert 未安装，跳过 PNG 生成"
    echo "  安装: brew install librsvg"
  else
    mkdir -p "$PREVIEW_DIR"
    # 清空旧预览
    find "$PREVIEW_DIR" -maxdepth 1 -name "${PREFIX}_*.png" -delete 2>/dev/null || true

    while IFS= read -r -d '' svg; do
      base="$(basename "$svg" .svg)"
      png="${PREVIEW_DIR}/${base}.png"
      rsvg-convert -w "$PNG_WIDTH" "$svg" -o "$png"
      printf "  %-40s -> %s\n" "$(basename "$svg")" "$(basename "$png")"
    done < <(find "$FLOORS_DIR" -maxdepth 1 -name "${PREFIX}_*.svg" -print0 | sort -z)

    PNG_COUNT=$(find "$PREVIEW_DIR" -maxdepth 1 -name "${PREFIX}_*.png" | wc -l | tr -d ' ')
    echo ""
    echo "=== PNG 完成: 生成 ${PNG_COUNT} 个预览图 ==="
    echo "预览目录: $PREVIEW_DIR"
  fi
else
  echo ""
  echo "=== [3/3] SVG → PNG 预览  (跳过，加 --png 启用) ==="
fi

echo ""
echo "================================================"
echo "全部完成"
echo "  SVG    : $FLOORS_DIR"
if [[ "$GEN_PNG" -eq 1 && -d "$PREVIEW_DIR" ]]; then
  echo "  PNG    : $PREVIEW_DIR"
fi
echo "================================================"
