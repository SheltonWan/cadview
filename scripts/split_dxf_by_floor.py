#!/usr/bin/env python3
"""
scripts/split_dxf_by_floor.py
按楼层切分 DXF Model Space，每张平面图输出一个独立 SVG。

工作原理：
  1. 在 Model Space 中扫描楼层标题文字（含 "X层平面图"），按 Y 排序
  2. 推算每张平面图的 Y 包围盒（上下两个标题的中点为分界）
  3. 对每个区域，用 ezdxf Frontend.draw_entities(filter_func=...) 仅渲染区域内实体
  4. 用每张图的实际 BoundingBox 作为 SVG 纸面尺寸输出

输出文件命名（合并图按"_"连接）：
  A座_F6-F8-F10.svg
  A座_F7-F9.svg
  A座_F11.svg
  A座_屋顶.svg
  ...

用法：
  python scripts/split_dxf_by_floor.py <input.dxf> <output_dir> [--prefix A座]

示例：
  python scripts/split_dxf_by_floor.py \
    cad_intermediate/building_a/A座.dxf \
    cad_intermediate/building_a/floors \
    --prefix A座
"""

import argparse
import re
import sys
from pathlib import Path
from typing import List, Tuple

import ezdxf
from ezdxf import bbox
from ezdxf.addons.drawing import Frontend, RenderContext
from ezdxf.addons.drawing import layout as drawing_layout
from ezdxf.addons.drawing.config import (
    Configuration,
    ColorPolicy,
    BackgroundPolicy,
    ProxyGraphicPolicy,
)
from ezdxf.addons.drawing.svg import SVGBackend
from ezdxf.math import BoundingBox2d, Vec2, Vec3

# 楼层平面图的图层黑名单（丢弃）：
#   - 轴网 / 尺寸标注 / 详图 / 装饰面层 / 修改痕迹 / 填充图案
# 其余图层全部保留（包括 WALL / WINDOW / COLU / TK / 0 / 8 / 房间名称 等）
FLOOR_PLAN_DROP_LAYERS = {
    # 轴网
    "AXIS", "柱网",
    # 尺寸标注
    "PUB_DIM", "PUB_TEXT", "详细标注", "详细尺寸", "详细尺寸-幕墙",
    "DIM_LEAD", "DIM_SYMB", "DIM_ELEV", "DIM_IDEN",
    "第二次修改标注", "A-ANNO-TEXT", "dote",
    # 详图 / 节点 / 剖面
    "节点", "0-节点(单玻铝板石材)",
    "A-SECT-MCUT", "A-SECT-MCUT-FINE", "A-SECT-MBND-FINE",
    "节点填充", "节点号修改",
    # 立面图
    "0-立面(轮廓)", "ELEV-4", "0-立面",
    # 修改痕迹
    "修改2016.03.17", "修改2016.01.22", "修改2015.10.15", "修改2015.11.04",
    "第二次修改", "结构梁问题",
    # 装饰面层 / 填充
    "面层", "铝板", "ALUM", "保温卷材", "保温板", "防水卷材",
    "hatch", "柱墙填充",  # 柱墙填充会遮住轮廓
    # 看线 / 可见看线
    "看线", "可见看线",
    # 门窗编号 / 幕墙编号（文本过多）
    "门窗编号", "门窗编号（回迁图纸）", "幕墙编号", "0-文字（防火门)",
    # 其他
    "排水", "BH", "栏杆", "标高号修改", "EQUIP_地漏", "DQ-L",
    # 门窗/幕墙编号（Chinese 短代号）
    "门窗编号（回迁图纸）",
    # 结构梁问题（修改痕迹）
    "结构梁问题",
    # 图签 / 标题块（右侧设计单位/图号/日期/项目名等）
    "TK",
    # 杂项编号层（仅含简短代号，无几何意义）
    "8", "0",
    # 重复的房间名称文字（"产业研发用房" × 22）：炸开后通过 TEXT_DROP 再抓一次
    "房间名称",
    # 空间填充 / 地面铺装（炸开后独立出现）
    "SPACE", "SPACE_HATCH", "A-FLOR-LAND", "HANDRAIL",
    # 空线本身：炸开前保留用于拿到 WALL/WINDOW 子实体；炸开后同名 LINE/LWPOLYLINE 仍残留 → 丢
    "空线",
}

# 需要整体炸开的复合 INSERT 图层（这些块把外墙+标注+面层混在一起）
# 炸开后，子实体按自身图层重新归位，可被 FLOOR_PLAN_DROP_LAYERS 精确过滤
# 注意：房号 INSERT 保留（那是 ① ② ③ 空间编号圆圈，有语义价值）
EXPLODE_INSERT_LAYERS = {"空线", "房号"}

# 直接按实体类型丢弃的类型集合
# - DIMENSION: 所有尺寸标注（炸开后从 INSERT 块里涌出大量 DIMENSION）
# 注意：ACAD_PROXY_ENTITY 必须保留——A座 DXF 里的外墙几何就以 proxy entity 形式存在，
# 靠 proxy_graphic_policy=SHOW 让 ezdxf 读取 proxy_graphic 缓存渲染
ENTITY_TYPE_DROP = {"DIMENSION"}

# 文本黑名单：实体类型为 TEXT/MTEXT 时，命中以下任一规则的整体丢弃
# 用于剔除散落在墙体内、无法整层 drop 的标注文字
# 注意：使用 re.search 而非 re.match，配合不带锚的模式，能匹配 MTEXT 多行内容中的片段
TEXT_DROP_PATTERNS = [
    re.compile(r"^FM\d"),               # 防火门编号 FM1521乙
    re.compile(r"^M\d{4}"),             # 门编号 M1021
    re.compile(r"^MQ[A-Z]"),            # 幕墙编号 MQA-6
    re.compile(r"^(SF|PY|PYY|QD|RD|PQ|DT\d?|JX-\d+|JAD-\d+|J[A-Z]-\d+)$"),  # 各类设备/分区代号
    re.compile(r"^\d+(\.\d+)?(m²?|m2)?$"),   # 纯数字 / 面积数字（71.47m²、4200）
    re.compile(r"^[、,，。]+$"),         # 标点
    # 核心筒装饰文字（炸开后从块里涌出）——用 search 匹配包含这些关键字的文本
    re.compile(r"(合用前室|消防电梯|无障碍|前室|电井|楼梯间|水井|管道井|公共卫生间|新风机房)"),
    re.compile(r"^产业[^$]*用房$"),       # "产业研发用房" 重复 22 次
    re.compile(r"^H[-+]?\d"),             # 标高 H-0.050
    re.compile(r"^\d+\.\d+$"),            # 浮点数（面积/尺寸）
    re.compile(r"^[A-Z]{1,3}-?\d{0,4}$"), # 短代号 A1、B-12、JA-02
    # 图签内容（TK 层整层 drop 后这些理论上不出现，作为兜底）
    re.compile(r"(注册章|制图|设计|校对|审核|审定|负责|比例|图号|版次|日期|阶段|项目名称|建设单位)"),
]

# 楼层标题正则：匹配 "A座6层平面图" / "A座6、8、10层平面图" / "A座屋顶平面图" / "A座屋顶构架平面图"
TITLE_RE = re.compile(
    r"^(?P<prefix>[A-Z]?座?)?\s*"
    r"(?P<floors>"
    r"(?:\d+(?:\s*[、,]\s*\d+)*\s*层)"  # 6层 / 6、8、10层
    r"|(?:屋顶(?:构架)?)"  # 屋顶 / 屋顶构架
    r")"
    r"\s*平面图\s*$"
)

# 楼层标识符正则（用于提取 6、8、10 这样的数字）
FLOOR_NUM_RE = re.compile(r"\d+")


def find_floor_titles(msp) -> List[Tuple[str, float, float, float, List[str]]]:
    """扫描楼层标题。

    Returns:
        List of (raw_text, x, y, height, floor_keys)
        floor_keys: 用于命名，如 ['F6', 'F8', 'F10'] 或 ['屋顶']
    """
    titles = []
    for e in msp:
        if e.dxftype() not in ("TEXT", "MTEXT"):
            continue
        text = e.dxf.get("text", "") if e.dxftype() == "TEXT" else e.text
        if not text:
            continue
        text = text.strip()
        if len(text) > 30:
            continue
        m = TITLE_RE.match(text)
        if not m:
            continue
        floors_part = m.group("floors")
        try:
            h = float(e.dxf.height)
        except Exception:
            h = 0.0
        # 仅保留较大字号的标题（过滤标注里的小字"21,23层此梁..."）
        if h < 400:
            continue

        if "屋顶" in floors_part:
            keys = ["屋顶构架"] if "构架" in floors_part else ["屋顶"]
        else:
            nums = FLOOR_NUM_RE.findall(floors_part)
            keys = [f"F{n}" for n in nums]

        titles.append((text, e.dxf.insert.x, e.dxf.insert.y, h, keys))
    return titles


def compute_floor_regions(
    titles: List[Tuple[str, float, float, float, List[str]]],
    msp_extents: BoundingBox2d,
) -> List[Tuple[str, List[str], BoundingBox2d]]:
    """根据标题位置计算每张平面图的 Y 区域。

    策略：
      - 平面图身体位于标题上方
      - 第 i 层 Y 上界 = 上一层标题 Y - 缓冲（避免上层底边 dote 挤入）
      - 第 i 层 Y 下界 = 本层标题 Y - 小缓冲（保留标题本身）
      - 最顶层（上方无邻居）使用 msp_max_y
    这样保证楼层间不重叠、不漏切，且不会被 A座 楼层高度差（64~80K）影响

    Returns:
        List of (label, floor_keys, BoundingBox2d)
        label: 用于文件名的稳定 ID，如 "F6-F8-F10" / "屋顶"
    """
    if not titles:
        return []

    # 按 Y 升序排列（Y 最小=最底部的标题=最低楼层图）
    titles_sorted = sorted(titles, key=lambda t: t[2])

    regions = []
    msp_min_x = msp_extents.extmin.x
    msp_max_x = msp_extents.extmax.x
    msp_max_y = msp_extents.extmax.y

    # 标题与下一层标题之间的安全带（避免互相串层）
    GAP = 2000
    # 标题自身保留余量（保留 "X 层平面图" 这几个字参与渲染；不强求）
    BOTTOM_PAD = 2000

    for i, (text, x, y, h, keys) in enumerate(titles_sorted):
        y_min = y - BOTTOM_PAD
        if i + 1 < len(titles_sorted):
            next_y = titles_sorted[i + 1][2]
            y_max = next_y - GAP
        else:
            y_max = msp_max_y

        label = "-".join(keys)
        # X 区域给大一点余量，避免外墙被裁（建筑进深约 ±40m）
        x_buffer = 45000
        x_min = max(msp_min_x, x - x_buffer)
        x_max = min(msp_max_x, x + x_buffer)
        bb = BoundingBox2d([Vec2(x_min, y_min), Vec2(x_max, y_max)])
        regions.append((label, keys, bb))

    return regions


def entity_in_region(entity, region: BoundingBox2d) -> bool:
    """判断实体是否在区域内（用包围盒中心点判定）。"""
    try:
        eb = bbox.extents([entity])
        if not eb.has_data:
            return False
        center = eb.center
        return region.inside(Vec3(center.x, center.y, 0))
    except Exception:
        return False


def render_region_to_svg(
    doc,
    msp,
    region: BoundingBox2d,
    output_path: str,
    label: str,
    entity_centers: dict,
    layer_drop: set,
) -> bool:
    """将指定区域内的实体渲染为独立 SVG。

    entity_centers: dict[id(entity)] = (cx, cy)，预先计算好以避免重复计算
    layer_drop: 丢弃这些图层名上的实体；其余全部保留
    """
    # 强制白底 + 全黑线条；忽略 CAD ACI 颜色
    # proxy_graphic_policy=SHOW: 让 ACAD_PROXY_ENTITY 的预览几何被渲染（尽管我们大多丢了它们，
    # 炸开后可能仍残留少量；开启此策略保证它们有视觉）
    config = Configuration(
        background_policy=BackgroundPolicy.WHITE,
        color_policy=ColorPolicy.BLACK,
        lineweight_scaling=0.4,
        proxy_graphic_policy=ProxyGraphicPolicy.SHOW,
    )
    ctx = RenderContext(doc)
    backend = SVGBackend()
    frontend = Frontend(ctx, backend, config=config)

    # 收集落在区域内的实体（区域过滤 + 图层黑名单 + 实体类型黑名单 + 文本黑名单 四重过滤）
    in_region = []
    region_min = region.extmin
    region_max = region.extmax
    for e in msp:
        # 实体类型黑名单：DIMENSION / ACAD_PROXY_ENTITY
        if e.dxftype() in ENTITY_TYPE_DROP:
            continue
        center = entity_centers.get(id(e))
        if center is None:
            continue
        cx, cy = center
        if not (region_min.x <= cx <= region_max.x and region_min.y <= cy <= region_max.y):
            continue
        if e.dxf.layer in layer_drop:
            continue
        # 文本黑名单：散落在墙体内、无法整层 drop 的标注文字
        if e.dxftype() in ("TEXT", "MTEXT"):
            try:
                txt = (e.dxf.text if e.dxftype() == "TEXT" else e.text).strip()
            except Exception:
                txt = ""
            if any(p.search(txt) for p in TEXT_DROP_PATTERNS):
                continue
        in_region.append(e)

    if not in_region:
        print(f"  [{label}] 区域内无实体（白名单过滤后），跳过")
        return False

    frontend.draw_entities(in_region)

    # 计算实际包围盒（白名单实体的真实 extents），用于裁剪 viewBox
    actual_bb = bbox.extents(in_region)
    if not actual_bb.has_data:
        print(f"  [{label}] 无法计算包围盒，跳过")
        return False

    sz = actual_bb.size
    # 把 DXF 单位（mm）按 1:10 缩到 SVG mm；最大宽 1500mm
    target_w = min(1500.0, sz.x / 10)
    target_h = target_w * (sz.y / sz.x) if sz.x > 0 else target_w

    page = drawing_layout.Page(
        width=target_w,
        height=target_h,
        units=drawing_layout.Units.mm,
    )
    settings = drawing_layout.Settings(fit_page=True)
    svg_string = backend.get_string(page, settings=settings)

    # 移除 ezdxf 默认注入的黑色背景 rect，并替换为白色背景
    # ezdxf 输出格式：<rect fill="#000000" x="0" y="0" width="..." height="..." fill-opacity="1.0" />
    svg_string = re.sub(
        r'<rect\s+fill=\"#000000\"\s+x=\"0\"\s+y=\"0\"[^/]*/>',
        '<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>',
        svg_string,
        count=1,
    )

    # 重写 ezdxf 输出的统一 stroke-width
    # ezdxf SVGBackend 把所有几何归到单一 .C1 类，原 stroke-width 约 67（在 1Mu × 1500mm viewBox 中
    # 等效 0.1mm，1600px PNG 上仅 ~0.1 像素，墙体几乎不可见）。
    # 重写为 1500 → 等效 2.25mm，1600px PNG 上 ~2.4 像素，墙体清晰可辨。
    svg_string = re.sub(
        r'(\.C1\s*\{[^}]*stroke-width:\s*)\d+',
        r'\g<1>1500',
        svg_string,
        count=1,
    )

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(svg_string, encoding="utf-8")
    print(
        f"  [{label}] 实体={len(in_region):>5d}  "
        f"尺寸={target_w:>6.1f}x{target_h:>6.1f}mm  "
        f"大小={len(svg_string)//1024:>4d}KB  -> {output_path}"
    )
    return True


def main():
    parser = argparse.ArgumentParser(description="按楼层切分 DXF 为 N 个独立 SVG")
    parser.add_argument("input", help="输入 DXF 文件路径")
    parser.add_argument("output_dir", help="输出 SVG 目录")
    parser.add_argument("--prefix", default="floor", help='输出文件名前缀，默认 "floor"')
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"错误: 输入文件不存在 - {args.input}", file=sys.stderr)
        sys.exit(1)

    print(f"读取 DXF: {args.input}")
    doc = ezdxf.readfile(args.input)
    msp = doc.modelspace()

    # 炸开复合 INSERT：把 "空线" 等图层的大块展开为独立子实体，
    # 让内部的 WALL/WINDOW/CURTWALL 能被保留，而 DIMENSION/dote/A-SECT-MCUT 能被精准过滤
    # 注意：INSERT 里的 ACAD_PROXY_ENTITY（125 个 WALL + 41 WINDOW 等）bbox 计算全部失败，
    # 无法通过 center-in-region 判定归属；这里记录每个 INSERT 的中心点，
    # 用作炸出后 proxy 子实体的"代理中心点"
    print(f"\n炸开复合 INSERT 层: {EXPLODE_INSERT_LAYERS}")
    to_explode = [e for e in msp if e.dxftype() == "INSERT" and e.dxf.layer in EXPLODE_INSERT_LAYERS]
    print(f"  找到 {len(to_explode)} 个待炸开的 INSERT")
    # 先记录每个 INSERT 的中心（炸开后才能拿到子实体，父 bbox 需提前算）
    insert_centers: List[Tuple[float, float]] = []
    for insert in to_explode:
        try:
            ib = bbox.extents([insert])
            if ib.has_data:
                insert_centers.append((ib.center.x, ib.center.y))
            else:
                ip = insert.dxf.insert
                insert_centers.append((ip.x, ip.y))
        except Exception:
            ip = insert.dxf.insert
            insert_centers.append((ip.x, ip.y))

    # 炸开并收集每批炸出的子实体 id 集合（用于映射 proxy 子实体→父中心）
    proxy_center_fallback: dict = {}  # id(entity) -> (cx, cy)
    exploded_total = 0
    for insert, pcenter in zip(to_explode, insert_centers):
        try:
            exploded = insert.explode()
            exploded_total += len(exploded)
            # 只为 bbox 不可算的 proxy 子实体记录 fallback 中心
            for sub in exploded:
                if sub.dxftype() == "ACAD_PROXY_ENTITY":
                    proxy_center_fallback[id(sub)] = pcenter
        except Exception as ex:
            print(f"  警告: 炸开失败 {insert.dxf.name}: {ex}")
    print(f"  炸开后新增 {exploded_total} 个独立子实体，其中 {len(proxy_center_fallback)} 个 proxy 使用父中心")

    # 计算 Model Space 总体 extents
    print("计算 Model Space 包围盒...")
    msp_bb = bbox.extents(msp)
    if not msp_bb.has_data:
        print("错误: Model Space 无可计算包围盒", file=sys.stderr)
        sys.exit(1)
    print(f"  Model 范围: {msp_bb.extmin} ~ {msp_bb.extmax}")

    # 找楼层标题
    print("扫描楼层标题...")
    titles = find_floor_titles(msp)
    print(f"  找到 {len(titles)} 条标题")
    for text, x, y, h, keys in sorted(titles, key=lambda t: -t[2]):
        print(f"    {text!r:<40s}  Y={y:>11.1f}  -> {keys}")

    if not titles:
        print("错误: 未找到任何楼层标题（含 'X层平面图' 的文字）", file=sys.stderr)
        sys.exit(1)

    # 计算楼层区域
    msp_2d = BoundingBox2d([
        Vec2(msp_bb.extmin.x, msp_bb.extmin.y),
        Vec2(msp_bb.extmax.x, msp_bb.extmax.y),
    ])
    regions = compute_floor_regions(titles, msp_2d)
    print(f"\n共 {len(regions)} 个楼层区域")

    # 一次性预计算所有实体的中心点（避免每个区域都重算）
    print("预计算所有实体中心点（用于区域归属判定）...")
    entity_centers = {}
    cache = bbox.Cache()
    skipped = 0
    proxy_fallback_used = 0
    for e in msp:
        try:
            eb = bbox.extents([e], cache=cache)
            if eb.has_data:
                c = eb.center
                entity_centers[id(e)] = (c.x, c.y)
                continue
        except Exception:
            pass
        # bbox 失败：若是炸开的 proxy，用父 INSERT 中心；否则跳过
        fc = proxy_center_fallback.get(id(e))
        if fc is not None:
            entity_centers[id(e)] = fc
            proxy_fallback_used += 1
        else:
            skipped += 1
    print(f"  完成: {len(entity_centers)} 个实体可定位 ({proxy_fallback_used} 个 proxy 用父中心), {skipped} 个跳过")

    print("\n开始渲染...")
    # 渲染每个区域
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    success = 0
    for label, keys, region in regions:
        out_file = out_dir / f"{args.prefix}_{label}.svg"
        if render_region_to_svg(
            doc, msp, region, str(out_file), label, entity_centers, FLOOR_PLAN_DROP_LAYERS
        ):
            success += 1

    print(f"\n完成: 成功渲染 {success}/{len(regions)} 个楼层")
    print(f"输出目录: {out_dir}")


if __name__ == "__main__":
    main()
