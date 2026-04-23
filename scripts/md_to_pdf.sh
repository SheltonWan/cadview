#!/usr/bin/env bash
# scripts/md_to_pdf.sh — Markdown → PDF 一键转换流水线
#
# 用法：
#   bash scripts/md_to_pdf.sh docs/backend/report.md
#   bash scripts/md_to_pdf.sh docs/frontend/*.md     # 批量
#
# 流程：docs/<subdir>/<name>.md → (中间).docx → pdfdocs/<subdir>/<name>.pdf → 删除 .docx
# 子目录结构自动镜像：docs/backend/x.md → pdfdocs/backend/x.pdf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$WORKSPACE/docs"
PDF_DIR="$WORKSPACE/pdfdocs"

# 优先使用项目 venv 的 Python，确保 python-docx/ezdxf 可用
VENV_PYTHON="$WORKSPACE/.venv/bin/python3"
if [[ -x "$VENV_PYTHON" ]]; then
    PYTHON="$VENV_PYTHON"
else
    PYTHON="python3"
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: bash scripts/md_to_pdf.sh <docs/[subdir/]file.md> [...]" >&2
    exit 1
fi

for MD_FILE in "$@"; do
    # 解析绝对路径
    ABS_MD="$(cd "$(dirname "$MD_FILE")" && pwd)/$(basename "$MD_FILE")"
    BASENAME="$(basename "$MD_FILE" .md)"

    # 计算相对于 docs/ 的子目录，以便镜像到 pdfdocs/
    ABS_MD_DIR="$(dirname "$ABS_MD")"
    REL_SUBDIR="${ABS_MD_DIR#$DOCS_DIR}"
    REL_SUBDIR="${REL_SUBDIR#/}"   # 去掉开头的 /

    # 构造中间 docx 路径（仍放在 md 同目录，转换后删除）
    DOCX="${ABS_MD_DIR}/${BASENAME}.docx"

    # 构造输出 PDF 路径（镜像子目录）
    if [[ -n "$REL_SUBDIR" ]]; then
        PDF_OUT_DIR="$PDF_DIR/$REL_SUBDIR"
    else
        PDF_OUT_DIR="$PDF_DIR"
    fi
    mkdir -p "$PDF_OUT_DIR"
    PDF="$PDF_OUT_DIR/${BASENAME}.pdf"

    echo "▶ [$REL_SUBDIR/$BASENAME]"
    echo "  md   → $DOCX"
    "$PYTHON" "$WORKSPACE/scripts/md2word.py" "$ABS_MD" "$DOCX"

    echo "  docx → $PDF"
    "$PYTHON" "$WORKSPACE/scripts/docx2pdf.py" "$DOCX" "$PDF"

    echo "  删除中间文件: $DOCX"
    rm "$DOCX"

    echo "  ✓ 完成: $PDF"
done
