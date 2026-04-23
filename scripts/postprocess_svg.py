#!/usr/bin/env python3
"""
scripts/postprocess_svg.py
SVG 后处理：注入标准热区样式 + 分层整理（floor-plan / unit-hotspots）

用法:
  python scripts/postprocess_svg.py <input.svg> <output.svg>
"""

import sys
from lxml import etree
from pathlib import Path

SVG_NS = "http://www.w3.org/2000/svg"

# 符合 SVG_HOTZONE_SPEC 的标准状态色样式
STANDARD_STYLES = """
      /* 状态色块 — 运行时由前端根据 unit.current_status 动态切换 class */
      .unit-leased        { fill: #4CAF50; fill-opacity: 0.35; stroke: #388E3C; stroke-width: 1; }
      .unit-vacant        { fill: #F44336; fill-opacity: 0.35; stroke: #D32F2F; stroke-width: 1; }
      .unit-expiring-soon { fill: #FF9800; fill-opacity: 0.35; stroke: #F57C00; stroke-width: 1; }
      .unit-renovating    { fill: #2196F3; fill-opacity: 0.35; stroke: #1976D2; stroke-width: 1; }
      .unit-non-leasable  { fill: #9E9E9E; fill-opacity: 0.20; stroke: #757575; stroke-width: 1; }
      /* hover 效果 */
      [data-unit-id]:hover { fill-opacity: 0.55; cursor: pointer; }
"""


def postprocess(input_path: str, output_path: str) -> None:
    tree = etree.parse(input_path)
    root = tree.getroot()

    # 1. 注入 <defs><style>（如果不存在）
    defs = root.find(f"{{{SVG_NS}}}defs")
    if defs is None:
        defs = etree.Element(f"{{{SVG_NS}}}defs")
        root.insert(0, defs)

    # 只要 id="propos-hotzone-styles" 的块不存在，就追加（不覆盖 ezdxf 原有样式）
    hotzone_style = defs.find(f"{{{SVG_NS}}}style[@id='propos-hotzone-styles']")
    if hotzone_style is None:
        style_el = etree.SubElement(defs, f"{{{SVG_NS}}}style")
        style_el.set("id", "propos-hotzone-styles")
        style_el.text = STANDARD_STYLES
        print("注入标准样式块")

    # 2. 将所有现有内容包裹到 <g id="floor-plan">
    floor_plan = root.find(f".//{{{SVG_NS}}}g[@id='floor-plan']")
    if floor_plan is None:
        floor_plan = etree.Element(f"{{{SVG_NS}}}g")
        floor_plan.set("id", "floor-plan")
        floor_plan.set("pointer-events", "none")

        # 移动非 defs 子元素到 floor-plan
        children_to_move = [
            child for child in list(root)
            if child.tag != f"{{{SVG_NS}}}defs"
        ]
        for child in children_to_move:
            root.remove(child)
            floor_plan.append(child)

        root.append(floor_plan)
        print(f"创建 floor-plan 层（包含 {len(children_to_move)} 个子元素）")

    # 3. 创建空的热区层
    hotspots = root.find(f".//{{{SVG_NS}}}g[@id='unit-hotspots']")
    if hotspots is None:
        hotspots = etree.SubElement(root, f"{{{SVG_NS}}}g")
        hotspots.set("id", "unit-hotspots")
        print("创建空的 unit-hotspots 层")

    # 写入输出文件
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    tree.write(output_path, xml_declaration=True, encoding="utf-8", pretty_print=True)
    print(f"后处理完成: {output_path}")


def main():
    if len(sys.argv) != 3:
        print("用法: python scripts/postprocess_svg.py <input.svg> <output.svg>", file=sys.stderr)
        sys.exit(1)
    postprocess(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
