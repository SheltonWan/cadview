#!/bin/bash
# scripts/cad_to_dxf.sh
# 将指定楼栋目录下的所有 DWG 文件批量转换为 DXF 格式
#
# 用法: bash scripts/cad_to_dxf.sh <building_folder>
# 示例: bash scripts/cad_to_dxf.sh building_a
#
# 输入目录: cad_source/<building_folder>/
# 输出目录: cad_intermediate/<building_folder>/
# 依赖工具: ODA File Converter（需已安装到 /Applications/）

set -euo pipefail

BUILDING="${1:-}"
if [[ -z "$BUILDING" ]]; then
  echo "错误: 请指定楼栋目录名"
  echo "用法: bash scripts/cad_to_dxf.sh <building_folder>"
  exit 1
fi

INPUT_DIR="cad_source/${BUILDING}"
OUTPUT_DIR="cad_intermediate/${BUILDING}"
ODA="/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter"

# 检查 ODA File Converter 是否安装
if [[ ! -x "$ODA" ]]; then
  echo "错误: ODA File Converter 未安装或路径不正确"
  echo "  期望路径: $ODA"
  echo "  请从 https://www.opendesign.com/guestfiles/oda_file_converter 下载安装"
  exit 1
fi

# 检查输入目录
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "错误: 输入目录不存在 — $INPUT_DIR"
  exit 1
fi

# 检查是否有 DWG 文件
DWG_COUNT=$(find "$INPUT_DIR" -maxdepth 1 -name "*.dwg" -o -name "*.DWG" | wc -l | tr -d ' ')
if [[ "$DWG_COUNT" -eq 0 ]]; then
  echo "错误: $INPUT_DIR 中没有找到 .dwg 文件"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== 开始 DWG → DXF 转换 ==="
echo "楼栋  : $BUILDING"
echo "输入  : ${INPUT_DIR}（共 ${DWG_COUNT} 个 DWG 文件）"
echo "输出  : $OUTPUT_DIR"
echo "格式  : ACAD2018 / DXF"
echo ""

# 调用 ODA File Converter
# 参数: <输入目录> <输出目录> <输出版本> <输出格式> <递归> <审计模式>
"$ODA" "$INPUT_DIR" "$OUTPUT_DIR" "ACAD2018" "DXF" "0" "1"

echo ""
echo "=== 转换完成 ==="

# 验证输出
DXF_COUNT=$(find "$OUTPUT_DIR" -maxdepth 1 -name "*.dxf" -o -name "*.DXF" | wc -l | tr -d ' ')
echo "输出 DXF 文件数: $DXF_COUNT / $DWG_COUNT"

# 检查空文件
EMPTY_COUNT=0
while IFS= read -r -d '' f; do
  if [[ ! -s "$f" ]]; then
    echo "⚠️  空文件: $f"
    EMPTY_COUNT=$((EMPTY_COUNT + 1))
  fi
done < <(find "$OUTPUT_DIR" -maxdepth 1 \( -name "*.dxf" -o -name "*.DXF" \) -print0)

if [[ "$DXF_COUNT" -eq "$DWG_COUNT" ]] && [[ "$EMPTY_COUNT" -eq 0 ]]; then
  echo "✅ 全部转换成功，共 $DXF_COUNT 个 DXF 文件"
  echo ""
  ls -lh "$OUTPUT_DIR"/*.dxf 2>/dev/null || ls -lh "$OUTPUT_DIR"/*.DXF 2>/dev/null
else
  echo "⚠️  转换可能不完整（空文件: $EMPTY_COUNT，数量不符或有异常）"
  echo "提示: 如 DXF 无输出，尝试将输出版本改为 ACAD2013"
  exit 1
fi
