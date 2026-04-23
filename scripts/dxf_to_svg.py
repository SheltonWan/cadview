#!/usr/bin/env python3
"""
scripts/dxf_to_svg.py
DXF -> SVG 自动转换脚本

用法:
  # 渲染模型空间（全楼总图，仅用于查看，不适合单楼层热区）
  python scripts/dxf_to_svg.py <input.dxf> <output.svg>

  # 渲染指定 Paper Space 布局（单楼层，推荐用于 PropOS 楼层热区）
  python scripts/dxf_to_svg.py <input.dxf> <output.svg> --layout "JX-63"

  # 列出 DXF 中所有可用布局（楼层）名称
  python scripts/dxf_to_svg.py <input.dxf> --list-layouts

示例：
  python scripts/dxf_to_svg.py cad_intermediate/building_a/A座.dxf out.svg --layout "JX-63"
"""

import argparse
import sys
from pathlib import Path

import ezdxf
from ezdxf.addons.drawing import RenderContext, Frontend
from ezdxf.addons.drawing import layout as drawing_layout
from ezdxf.addons.drawing.svg import SVGBackend


def list_layouts(input_path: str) -> None:
    """列出 DXF 文件中所有可用布局（含实体数量）。"""
    doc = ezdxf.readfile(input_path)
    names = list(doc.layouts.names())
    print(f"DXF 文件: {input_path}")
    print(f"可用布局 ({len(names)} 个):")
    for n in names:
        ly = doc.layouts.get(n)
        count = sum(1 for _ in ly)
        marker = " [Paper Space]" if n != "Model" else " [Model Space]"
        print(f"  {repr(n)}{marker}  entities={count}")


def convert_dxf_to_svg(
    input_path: str,
    output_path: str,
    layout_name: str = "Model",
) -> None:
    """将 DXF 文件的指定布局转换为 SVG。

    Args:
        input_path:   DXF 文件路径
        output_path:  输出 SVG 文件路径
        layout_name:  要渲染的布局名称。
                      - "Model"：模型空间（全图），适合查看，不适合单楼层热区
                      - Paper Space 布局名（如 "JX-63"）：推荐用于楼层热区 SVG
    """
    doc = ezdxf.readfile(input_path)
    layout = doc.layouts.get(layout_name)
    if layout is None:
        print(f"错误: 找不到布局 {layout_name!r}", file=sys.stderr)
        print("可用布局:", list(doc.layouts.names()), file=sys.stderr)
        sys.exit(1)

    ctx = RenderContext(doc)
    backend = SVGBackend()
    frontend = Frontend(ctx, backend)
    frontend.draw_layout(layout)

    # Paper Space 布局使用 DXF 纸张定义尺寸；Model 空间用 A1 横向兜底
    if layout_name != "Model":
        dxf = layout.dxf
        pw = getattr(dxf, "paper_width", None)
        ph = getattr(dxf, "paper_height", None)
        if pw and ph:
            page = drawing_layout.Page(
                width=float(pw),
                height=float(ph),
                units=drawing_layout.Units.mm,
            )
        else:
            page = drawing_layout.Page(
                width=594.0,
                height=841.0,
                units=drawing_layout.Units.mm,
            )
    else:
        # Model 空间尺寸由内容 extents 自动决定；使用 A0 横向兜底，fit_page 裁切
        page = drawing_layout.Page(
            width=1189.0,
            height=841.0,
            units=drawing_layout.Units.mm,
        )

    settings = drawing_layout.Settings(fit_page=True)
    svg_string = backend.get_string(page, settings=settings)

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(svg_string, encoding="utf-8")
    print(f"转换完成: [{layout_name}] {input_path} -> {output_path}")
    print(f"文件大小: {len(svg_string) // 1024} KB")


def main():
    parser = argparse.ArgumentParser(description="DXF -> SVG 转换工具（支持 Model / Paper Space 布局）")
    parser.add_argument("input", help="输入 DXF 文件路径")
    parser.add_argument("output", nargs="?", help="输出 SVG 文件路径（--list-layouts 时可省略）")
    parser.add_argument("--layout", default="Model", help='渲染的布局名称，默认 "Model"（模型空间）')
    parser.add_argument("--list-layouts", action="store_true", help="列出 DXF 中所有布局后退出")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"错误: 输入文件不存在 - {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.list_layouts:
        list_layouts(args.input)
        return

    if not args.output:
        print("错误: 请指定输出 SVG 路径", file=sys.stderr)
        sys.exit(1)

    convert_dxf_to_svg(args.input, args.output, args.layout)


if __name__ == "__main__":
    main()
