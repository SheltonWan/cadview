#!/usr/bin/env python3
"""
scripts/annotate_hotzones.py
命令行版"热区图导出"。

对标 Flutter 应用中的导出流程（见 cad_viewer_builder/src/App.vue 里
`extractUnits` / `exportSvgWithUnits`）：

  1. 读取 DXF，按指定"边界图层"收集所有闭合多段线/Hatch/圆作为单元候选
  2. 如提供"文字图层"，用质心包含法匹配文字到单元，推断 unit_number
  3. 用 ezdxf SVGBackend 渲染 DXF → 原始 SVG（保留全图线稿）
  4. 后处理：注入 SVG_HOTZONE_SPEC 标准样式、包裹 floor-plan、追加
     unit-hotspots 层，为每个单元生成 <rect data-unit-id data-unit-number>
  5. 同步输出 floor_map JSON（viewport + units[]，与 ExportService 保持一致）

用法：
  # 查看 DXF 可用图层（筛选出含闭合形状最多的前 N 个）
  python scripts/annotate_hotzones.py <input.dxf> --list-layers

  # 查看 DXF 可用布局
  python scripts/annotate_hotzones.py <input.dxf> --list-layouts

  # 导出热区图
  python scripts/annotate_hotzones.py <input.dxf> \\
      --boundary-layer SPACE \\
      --label-layers 房号,文字 \\
      --layout Model \\
      --status vacant \\
      --out-svg  out/1F_hotspot.svg \\
      --out-json out/1F_hotspot.json
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

import ezdxf
from ezdxf import bbox
from ezdxf.addons.drawing import Frontend, RenderContext
from ezdxf.addons.drawing import layout as drawing_layout
from ezdxf.addons.drawing.svg import SVGBackend
from ezdxf.math import BoundingBox2d
from lxml import etree

SVG_NS = "http://www.w3.org/2000/svg"
NSMAP = {"svg": SVG_NS}

# 与 cad_viewer_builder/src/App.vue 的 HOTSPOT_STYLES + postprocess_svg.py 完全一致
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

VALID_STATUSES = {
    "vacant",
    "leased",
    "expiring-soon",
    "renovating",
    "non-leasable",
}


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------


@dataclass
class UnitDxf:
    """DXF 空间中的一个单元候选。"""

    index: int
    min_x: float
    min_y: float
    max_x: float
    max_y: float
    label: str = ""
    unit_id: str = field(default_factory=lambda: str(uuid.uuid4()))

    @property
    def width(self) -> float:
        return self.max_x - self.min_x

    @property
    def height(self) -> float:
        return self.max_y - self.min_y

    @property
    def centroid(self) -> Tuple[float, float]:
        return ((self.min_x + self.max_x) / 2, (self.min_y + self.max_y) / 2)


@dataclass
class SvgTransform:
    """
    把 DXF 坐标转到 SVG viewBox 坐标（用于写 hotspot rect / JSON bounds）。

    ezdxf 的 SVGBackend（fit_page=True，保持纵横比）的等价变换：
      svg_x =  dxf_x * scale + tx
      svg_y = -dxf_y * scale + ty
    其中
      scale = min(page_w / content_w, page_h / content_h)
      tx = (page_w - content_w * scale) / 2 - content_min_x * scale
      ty = (page_h - content_h * scale) / 2 + content_max_y * scale
    """

    scale: float
    tx: float
    ty: float
    viewport_w: float
    viewport_h: float

    def map_rect(self, u: UnitDxf) -> Tuple[float, float, float, float]:
        # 左上角对应 (min_x, max_y) in DXF
        x = u.min_x * self.scale + self.tx
        y = -u.max_y * self.scale + self.ty
        w = u.width * self.scale
        h = u.height * self.scale
        return x, y, w, h


# ---------------------------------------------------------------------------
# DXF 扫描
# ---------------------------------------------------------------------------


_CLOSED_POLYLINE_TYPES = {"LWPOLYLINE", "POLYLINE"}
_BOUNDARY_SHAPE_TYPES = {"HATCH", "CIRCLE", "ELLIPSE"}
_TEXT_TYPES = {"TEXT", "MTEXT"}


def _iter_layout_entities(layout) -> Iterable:
    # Paper Space 的 layout 也可迭代
    return iter(layout)


def _is_closed_boundary(entity) -> bool:
    t = entity.dxftype()
    if t in _CLOSED_POLYLINE_TYPES:
        try:
            return bool(entity.closed)
        except AttributeError:
            # 老版本 POLYLINE：检查 flags bit 1
            flags = getattr(entity.dxf, "flags", 0)
            return bool(flags & 1)
    return t in _BOUNDARY_SHAPE_TYPES


def _text_content(entity) -> str:
    t = entity.dxftype()
    try:
        if t == "MTEXT":
            return (entity.text or "").strip()
        if t == "TEXT":
            return (entity.dxf.text or "").strip()
    except Exception:
        pass
    return ""


def _text_position(entity) -> Optional[Tuple[float, float]]:
    try:
        if entity.dxftype() == "MTEXT":
            ins = entity.dxf.insert
        else:
            ins = entity.dxf.insert
        return float(ins.x), float(ins.y)
    except Exception:
        return None


def _entity_bbox(entity) -> Optional[Tuple[float, float, float, float]]:
    try:
        bb = bbox.extents([entity])
    except Exception:
        return None
    if not bb.has_data:
        return None
    mn, mx = bb.extmin, bb.extmax
    return float(mn.x), float(mn.y), float(mx.x), float(mx.y)


def collect_units(
    layout,
    boundary_layer: str,
    label_layers: List[str],
) -> List[UnitDxf]:
    units: List[UnitDxf] = []
    labels: List[Tuple[float, float, str]] = []
    label_set = set(label_layers)

    for e in _iter_layout_entities(layout):
        layer = getattr(e.dxf, "layer", "")
        if layer == boundary_layer and _is_closed_boundary(e):
            bb = _entity_bbox(e)
            if bb is None:
                continue
            mn_x, mn_y, mx_x, mx_y = bb
            units.append(
                UnitDxf(
                    index=len(units),
                    min_x=mn_x,
                    min_y=mn_y,
                    max_x=mx_x,
                    max_y=mx_y,
                )
            )
        elif label_set and layer in label_set and e.dxftype() in _TEXT_TYPES:
            text = _text_content(e)
            if not text:
                continue
            pos = _text_position(e)
            if pos is None:
                continue
            labels.append((pos[0], pos[1], text))

    # 质心包含匹配：第一个命中即采用
    for lx, ly, text in labels:
        for u in units:
            if u.label:
                continue
            if u.min_x <= lx <= u.max_x and u.min_y <= ly <= u.max_y:
                u.label = text
                break

    return units


def layer_stats(layout) -> List[dict]:
    stats: dict[str, dict] = {}

    def touch(name: str) -> dict:
        s = stats.get(name)
        if s is None:
            s = {
                "name": name,
                "closed_polyline": 0,
                "hatch": 0,
                "circle": 0,
                "text": 0,
                "total": 0,
            }
            stats[name] = s
        return s

    for e in _iter_layout_entities(layout):
        layer = getattr(e.dxf, "layer", "")
        s = touch(layer)
        s["total"] += 1
        t = e.dxftype()
        if t in _CLOSED_POLYLINE_TYPES and _is_closed_boundary(e):
            s["closed_polyline"] += 1
        elif t == "HATCH":
            s["hatch"] += 1
        elif t in ("CIRCLE", "ELLIPSE"):
            s["circle"] += 1
        elif t in _TEXT_TYPES:
            s["text"] += 1

    # 按"闭合形状优先"的得分排序
    def score(s: dict) -> int:
        return s["closed_polyline"] * 3 + s["hatch"] * 2 + s["circle"]

    return sorted(stats.values(), key=score, reverse=True)


# ---------------------------------------------------------------------------
# SVG 渲染 + 后处理
# ---------------------------------------------------------------------------


def _content_bbox(layout) -> Optional[BoundingBox2d]:
    bb = bbox.extents(layout)
    if not bb.has_data:
        return None
    return BoundingBox2d([bb.extmin, bb.extmax])


def _choose_page(
    layout_name: str,
    content_bb: Optional[BoundingBox2d],
) -> drawing_layout.Page:
    """与 dxf_to_svg.py 保持一致的页面选择策略。"""
    if layout_name != "Model" and content_bb is None:
        # Paper Space 兜底
        return drawing_layout.Page(
            width=594.0, height=841.0, units=drawing_layout.Units.mm
        )
    # Model / 有 extents：给足够的兜底尺寸，交给 fit_page 自动收缩
    return drawing_layout.Page(
        width=1189.0, height=841.0, units=drawing_layout.Units.mm
    )


def render_svg_and_transform(
    doc,
    layout_name: str,
) -> Tuple[str, SvgTransform]:
    layout = doc.layouts.get(layout_name)
    if layout is None:
        raise SystemExit(
            f"错误: 找不到布局 {layout_name!r}，可用布局：{list(doc.layouts.names())}"
        )

    content_bb = _content_bbox(layout)
    if content_bb is None:
        raise SystemExit("错误: 布局内容为空，无法计算包围盒")

    # Paper Space 可能带 paper_width/height，保持与 dxf_to_svg.py 一致的策略
    if layout_name != "Model":
        dxf_attrs = layout.dxf
        pw = getattr(dxf_attrs, "paper_width", None)
        ph = getattr(dxf_attrs, "paper_height", None)
        if pw and ph:
            page = drawing_layout.Page(
                width=float(pw), height=float(ph), units=drawing_layout.Units.mm
            )
        else:
            page = _choose_page(layout_name, content_bb)
    else:
        page = _choose_page(layout_name, content_bb)

    ctx = RenderContext(doc)
    backend = SVGBackend()
    frontend = Frontend(ctx, backend)
    frontend.draw_layout(layout)

    settings = drawing_layout.Settings(fit_page=True)
    svg_text = backend.get_string(page, settings=settings)

    # viewBox 与 Page 尺寸一致（ezdxf 会按 mm 转成 SVG user units，viewBox 就是 mm 数值）
    # 但我们解析 viewBox 以求稳
    viewport_w, viewport_h = _parse_viewbox(svg_text, page)

    # 计算 fit_page + preserve aspect ratio 的等价变换
    content_w = max(content_bb.extmax.x - content_bb.extmin.x, 1e-9)
    content_h = max(content_bb.extmax.y - content_bb.extmin.y, 1e-9)
    scale = min(viewport_w / content_w, viewport_h / content_h)
    tx = (viewport_w - content_w * scale) / 2 - content_bb.extmin.x * scale
    ty = (viewport_h - content_h * scale) / 2 + content_bb.extmax.y * scale

    return svg_text, SvgTransform(
        scale=scale, tx=tx, ty=ty, viewport_w=viewport_w, viewport_h=viewport_h
    )


def _parse_viewbox(svg_text: str, page: drawing_layout.Page) -> Tuple[float, float]:
    try:
        root = etree.fromstring(svg_text.encode("utf-8"))
    except etree.XMLSyntaxError:
        return float(page.width), float(page.height)
    vb = root.get("viewBox")
    if not vb:
        return float(page.width), float(page.height)
    parts = vb.strip().split()
    if len(parts) < 4:
        return float(page.width), float(page.height)
    try:
        return abs(float(parts[2])), abs(float(parts[3]))
    except ValueError:
        return float(page.width), float(page.height)


def postprocess_svg(
    svg_text: str,
    units: List[UnitDxf],
    transform: SvgTransform,
    status: str,
) -> Tuple[str, List[dict], Tuple[int, int]]:
    root = etree.fromstring(svg_text.encode("utf-8"))

    # 1. <defs><style>
    defs = root.find(f"{{{SVG_NS}}}defs")
    if defs is None:
        defs = etree.Element(f"{{{SVG_NS}}}defs")
        root.insert(0, defs)
    if defs.find(f"{{{SVG_NS}}}style[@id='propos-hotzone-styles']") is None:
        style_el = etree.SubElement(defs, f"{{{SVG_NS}}}style")
        style_el.set("id", "propos-hotzone-styles")
        style_el.text = STANDARD_STYLES

    # 2. floor-plan 包裹
    floor_plan = root.find(f".//{{{SVG_NS}}}g[@id='floor-plan']")
    if floor_plan is None:
        floor_plan = etree.Element(f"{{{SVG_NS}}}g")
        floor_plan.set("id", "floor-plan")
        floor_plan.set("pointer-events", "none")
        to_move = [c for c in list(root) if c.tag != f"{{{SVG_NS}}}defs"]
        for c in to_move:
            root.remove(c)
            floor_plan.append(c)
        root.append(floor_plan)

    # 3. unit-hotspots
    hotspots = root.find(f".//{{{SVG_NS}}}g[@id='unit-hotspots']")
    if hotspots is None:
        hotspots = etree.SubElement(root, f"{{{SVG_NS}}}g")
        hotspots.set("id", "unit-hotspots")

    unit_entries: List[dict] = []
    for idx, u in enumerate(units, start=1):
        x, y, w, h = transform.map_rect(u)
        rx, ry = round(x), round(y)
        rw, rh = max(round(w), 0), max(round(h), 0)

        unit_number = u.label if u.label else f"U{idx:03d}"

        rect = etree.SubElement(hotspots, f"{{{SVG_NS}}}rect")
        rect.set("data-unit-id", u.unit_id)
        rect.set("data-unit-number", unit_number)
        rect.set("class", f"unit-{status}")
        rect.set("x", str(rx))
        rect.set("y", str(ry))
        rect.set("width", str(rw))
        rect.set("height", str(rh))

        unit_entries.append(
            {
                "unit_id": u.unit_id,
                "unit_number": unit_number,
                "shape": "rect",
                "bounds": {"x": rx, "y": ry, "width": rw, "height": rh},
                "label_position": {
                    "x": rx + round(rw / 2),
                    "y": ry + round(rh / 2),
                },
            }
        )

    viewport = (int(round(transform.viewport_w)), int(round(transform.viewport_h)))
    out_svg = etree.tostring(
        root, xml_declaration=True, encoding="utf-8", pretty_print=True
    ).decode("utf-8")
    return out_svg, unit_entries, viewport


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def cmd_list_layouts(dxf_path: Path) -> None:
    doc = ezdxf.readfile(str(dxf_path))
    names = list(doc.layouts.names())
    print(f"DXF: {dxf_path}")
    print(f"布局 ({len(names)} 个):")
    for n in names:
        marker = "[Paper]" if n != "Model" else "[Model]"
        ly = doc.layouts.get(n)
        count = sum(1 for _ in ly)
        print(f"  {marker} {n!r}  entities={count}")


def cmd_list_layers(dxf_path: Path, layout_name: str, top: int) -> None:
    doc = ezdxf.readfile(str(dxf_path))
    layout = doc.layouts.get(layout_name)
    if layout is None:
        raise SystemExit(
            f"错误: 找不到布局 {layout_name!r}，可用布局：{list(doc.layouts.names())}"
        )
    stats = layer_stats(layout)
    print(f"DXF: {dxf_path}  布局: {layout_name}")
    print(f"图层 (按闭合形状评分排序，前 {top} 个):")
    print(
        f"  {'LAYER':<32} {'CLOSED':>7} {'HATCH':>6} {'CIRCLE':>7}"
        f" {'TEXT':>6} {'TOTAL':>7}"
    )
    for s in stats[:top]:
        print(
            f"  {s['name'][:32]:<32} {s['closed_polyline']:>7}"
            f" {s['hatch']:>6} {s['circle']:>7} {s['text']:>6} {s['total']:>7}"
        )


def cmd_export(args: argparse.Namespace) -> None:
    dxf_path = Path(args.dxf)
    if not dxf_path.exists():
        raise SystemExit(f"错误: DXF 不存在 — {dxf_path}")
    if args.status not in VALID_STATUSES:
        raise SystemExit(
            f"错误: --status 必须为 {sorted(VALID_STATUSES)} 之一"
        )

    label_layers = [s for s in (args.label_layers or "").split(",") if s.strip()]
    label_layers = [s.strip() for s in label_layers]

    doc = ezdxf.readfile(str(dxf_path))
    layout = doc.layouts.get(args.layout)
    if layout is None:
        raise SystemExit(
            f"错误: 找不到布局 {args.layout!r}，可用布局：{list(doc.layouts.names())}"
        )

    # 1. 提取单元
    units = collect_units(layout, args.boundary_layer, label_layers)
    if not units:
        raise SystemExit(
            f"错误: 图层 {args.boundary_layer!r} 下未找到闭合形状。"
            f"用 --list-layers 查看候选图层。"
        )
    print(
        f"[1/3] 提取单元：{len(units)} 个（匹配到文字 "
        f"{sum(1 for u in units if u.label)} 个）"
    )

    # 2. 渲染 SVG + 计算变换
    svg_text, transform = render_svg_and_transform(doc, args.layout)
    print(
        f"[2/3] 渲染 SVG：viewport={int(transform.viewport_w)}x"
        f"{int(transform.viewport_h)}  scale={transform.scale:.4f}"
    )

    # 3. 注入样式、分层、加 rect
    out_svg, unit_entries, viewport = postprocess_svg(
        svg_text, units, transform, args.status
    )
    print(f"[3/3] 注入 {len(unit_entries)} 个热区 rect")

    # 写文件
    out_svg_path = Path(args.out_svg)
    out_json_path = Path(args.out_json)
    out_svg_path.parent.mkdir(parents=True, exist_ok=True)
    out_json_path.parent.mkdir(parents=True, exist_ok=True)
    out_svg_path.write_text(out_svg, encoding="utf-8")

    floor_id = args.floor_id or str(uuid.uuid4())
    building_id = args.building_id or str(uuid.uuid4())
    payload = {
        "floor_id": floor_id,
        "building_id": building_id,
        "svg_version": date.today().isoformat(),
        "viewport": {"width": viewport[0], "height": viewport[1]},
        "units": unit_entries,
    }
    out_json_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print("")
    print(f"SVG  -> {out_svg_path}")
    print(f"JSON -> {out_json_path}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="从 DXF 生成热区图 SVG + floor_map JSON（脚本化版导出）",
    )
    p.add_argument("dxf", help="输入 DXF 路径")

    # 互斥的操作模式
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--list-layouts", action="store_true", help="列出 DXF 中的所有布局后退出"
    )
    mode.add_argument(
        "--list-layers",
        action="store_true",
        help="列出指定布局下的图层统计（按闭合形状评分排序）",
    )

    p.add_argument(
        "--layout",
        default="Model",
        help='渲染/扫描的布局名，默认 "Model"（模型空间）',
    )
    p.add_argument(
        "--top", type=int, default=30, help="--list-layers 时显示前 N 行，默认 30"
    )

    # 导出参数
    p.add_argument("--boundary-layer", help="边界图层名（每个闭合多段线/Hatch = 一个单元）")
    p.add_argument(
        "--label-layers",
        default="",
        help="文字图层名，逗号分隔；可选，用于自动匹配 unit_number",
    )
    p.add_argument(
        "--status",
        default="vacant",
        help=f"初始状态 class，默认 vacant；可选 {sorted(VALID_STATUSES)}",
    )
    p.add_argument("--out-svg", help="输出 SVG 路径（导出模式必填）")
    p.add_argument("--out-json", help="输出 JSON 路径（导出模式必填）")
    p.add_argument("--floor-id", help="floor_id UUID，省略则自动生成")
    p.add_argument("--building-id", help="building_id UUID，省略则自动生成")
    return p


def main() -> None:
    args = build_parser().parse_args()
    dxf_path = Path(args.dxf)
    if not dxf_path.exists():
        raise SystemExit(f"错误: DXF 不存在 — {dxf_path}")

    if args.list_layouts:
        cmd_list_layouts(dxf_path)
        return
    if args.list_layers:
        cmd_list_layers(dxf_path, args.layout, args.top)
        return

    missing = [k for k in ("boundary_layer", "out_svg", "out_json")
               if getattr(args, k) in (None, "")]
    if missing:
        raise SystemExit(
            f"错误: 导出模式下必填参数缺失：{missing}\n"
            f"用 -h 查看说明。"
        )
    cmd_export(args)


if __name__ == "__main__":
    main()
