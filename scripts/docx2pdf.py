#!/usr/bin/env python3
"""
docx2pdf.py — Word (.docx) → PDF 转换工具

转换链路：通过 macOS Pages App (AppleScript) 原生渲染导出 PDF
  • 排版质量与手动用 Pages 导出完全一致
  • 保留标题层级、表格、代码块、字体等所有格式

用法：
    python3 docx2pdf.py <input.docx>               # 同目录输出同名 .pdf
    python3 docx2pdf.py <input.docx> <output.pdf>  # 指定输出路径
    python3 docx2pdf.py *.docx                     # 批量转换

依赖：
    • macOS Pages App（系统自带）
"""

import sys, os, argparse, subprocess, textwrap, time


# ═══════════════════════════════════════════════
#  通过 macOS Pages App (AppleScript) 导出 PDF
# ═══════════════════════════════════════════════
def _convert_via_pages(docx_abs: str, pdf_abs: str) -> bool:
    """用 AppleScript 驱动 Pages 打开 docx 并导出为 PDF"""
    os.makedirs(os.path.dirname(pdf_abs) or '.', exist_ok=True)

    # 构造 AppleScript：打开文件 → 导出 PDF → 关闭文档
    applescript = f'''
        tell application "Pages"
            activate
            set docPath to POSIX file "{docx_abs}"
            set pdfPath to POSIX file "{pdf_abs}"
            open docPath
            delay 2
            -- 等待文档完全加载
            set theDoc to front document
            repeat while not (exists theDoc)
                delay 0.5
            end repeat
            delay 1
            export theDoc to pdfPath as PDF
            close theDoc saving no
        end tell
    '''

    result = subprocess.run(
        ['osascript', '-e', applescript],
        capture_output=True, text=True, timeout=120,
    )

    if result.returncode != 0:
        print(f'  Pages 导出失败: {result.stderr.strip()}', file=sys.stderr)
        return False

    # 验证 PDF 文件已生成
    deadline = time.time() + 10
    while time.time() < deadline:
        if os.path.isfile(pdf_abs) and os.path.getsize(pdf_abs) > 1024:
            return True
        time.sleep(0.5)

    return os.path.isfile(pdf_abs) and os.path.getsize(pdf_abs) > 1024


# ═══════════════════════════════════════════════
#  主转换函数
# ═══════════════════════════════════════════════
def convert(docx_path: str, pdf_path: str):
    docx_abs = os.path.abspath(docx_path)
    pdf_abs  = os.path.abspath(pdf_path)

    if not os.path.isfile(docx_abs):
        print(f'❌  找不到文件：{docx_path}', file=sys.stderr)
        return False

    print(f'📄  {os.path.basename(docx_abs)}  →  {pdf_abs}')

    if _convert_via_pages(docx_abs, pdf_abs):
        print(f'✅  完成')
        return True

    print(textwrap.dedent(f"""
    ❌  转换失败：{os.path.basename(docx_abs)}
    """), file=sys.stderr)
    return False


# ═══════════════════════════════════════════════
#  命令行入口
# ═══════════════════════════════════════════════
def main():
    ap = argparse.ArgumentParser(
        description='Word (.docx) → PDF（支持目录书签）',
        epilog=textwrap.dedent('''\
            示例：
              python3 docx2pdf.py report.docx
              python3 docx2pdf.py report.docx output.pdf
              python3 docx2pdf.py *.docx
        '''),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument('args',          nargs='+', help='输入 .docx 文件（可多个）；若最后一个以 .pdf 结尾则视为输出路径')
    ap.add_argument('-o', '--output',           help='指定输出路径（仅单文件时有效）')
    parsed = ap.parse_args()

    positional = parsed.args

    # 自动识别第二个参数为输出路径
    if len(positional) >= 2 and positional[-1].lower().endswith('.pdf'):
        inputs     = positional[:-1]
        out_single = positional[-1]
    else:
        inputs     = positional
        out_single = parsed.output

    if len(inputs) > 1 and out_single:
        print('⚠️  多文件模式下忽略指定输出路径，自动按输入文件名生成。', file=sys.stderr)
        out_single = None

    ok = fail = 0
    for docx in inputs:
        if out_single and len(inputs) == 1:
            pdf = os.path.abspath(out_single)
        else:
            pdf = os.path.splitext(os.path.abspath(docx))[0] + '.pdf'

        if convert(docx, pdf):
            ok += 1
        else:
            fail += 1

    if len(inputs) > 1:
        print(f'\n共 {ok + fail} 个文件：{ok} 成功，{fail} 失败')


if __name__ == '__main__':
    main()
