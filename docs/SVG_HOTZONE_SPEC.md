# SVG 热区绑定规范

> **文档版本**: v1.0
> **更新日期**: 2026-04-08
> **对应模块**: M1 资产与空间可视化

---

## 一、概述

楼层 SVG 文件由 CAD（DWG → DXF → SVG）自动转换后，需要人工标注"热区"以实现：
1. 点击单元色块查看详情 / 弹出快捷操作
2. 状态色块着色（已租 / 空置 / 非可租等）
3. Flutter 移动端 / Admin PC 端交互渲染

本文档定义 SVG 文件内单元热区的标记规范和配套 JSON 映射文件格式。

---

## 二、SVG 标记规范

### 2.1 单元热区元素

每个可交互的单元区域使用 `<rect>`、`<polygon>` 或 `<path>` 元素表示，并**必须包含以下自定义属性**：

| 属性 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `data-unit-id` | UUID | 是 | 对应 `units.id`，全局唯一 |
| `data-unit-number` | string | 是 | 展示用编号（如 `101`、`S101`），与 `units.unit_number` 一致 |
| `class` | string | 是 | 状态 CSS class，默认 `unit-vacant`，由前端运行时动态替换 |

### 2.2 SVG 内嵌样式定义

SVG 文件头部必须包含以下样式块，颜色值对应 Material 3 Theme Token：

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">
  <defs>
    <style>
      /* 状态色块 — 运行时由前端根据 unit.current_status 动态切换 class */
      .unit-leased       { fill: #4CAF50; fill-opacity: 0.35; stroke: #388E3C; stroke-width: 1; }
      .unit-vacant        { fill: #F44336; fill-opacity: 0.35; stroke: #D32F2F; stroke-width: 1; }
      .unit-expiring-soon { fill: #FF9800; fill-opacity: 0.35; stroke: #F57C00; stroke-width: 1; }
      .unit-renovating    { fill: #2196F3; fill-opacity: 0.35; stroke: #1976D2; stroke-width: 1; }
      .unit-non-leasable  { fill: #9E9E9E; fill-opacity: 0.20; stroke: #757575; stroke-width: 1; }
      /* hover 效果 */
      [data-unit-id]:hover { fill-opacity: 0.55; cursor: pointer; }
    </style>
  </defs>

  <!-- 楼层底图（CAD 转换的线稿） -->
  <g id="floor-plan">
    <!-- ... CAD 转换的 path/line 元素 ... -->
  </g>

  <!-- 单元热区层（覆盖在底图之上） -->
  <g id="unit-hotspots">
    <rect data-unit-id="c0000000-0000-0000-0000-000000000001"
          data-unit-number="101"
          class="unit-leased"
          x="120" y="50" width="200" height="150" />
    <polygon data-unit-id="c0000000-0000-0000-0000-000000000002"
             data-unit-number="102"
             class="unit-leased"
             points="330,50 530,50 530,200 330,200" />
    <!-- 非规则形状用 path -->
    <path data-unit-id="c0000000-0000-0000-0000-000000000003"
          data-unit-number="103"
          class="unit-vacant"
          d="M 540,50 L 740,50 L 740,250 L 640,250 L 640,150 L 540,150 Z" />
  </g>
</svg>
```

### 2.3 分层要求

| 图层 `<g>` ID | 内容 | 交互 |
|---------------|------|------|
| `floor-plan` | CAD 转换的建筑线稿、走廊、楼梯等 | 不可交互，`pointer-events: none` |
| `unit-hotspots` | 单元热区元素 | 可点击、可 hover |
| `labels`（可选） | 单元编号文字标注 | 不可交互 |

---

## 三、楼层映射文件（floor_map.json）

每个楼层 SVG 配套一份 JSON 映射文件，存储在同目录下：

```
floors/{building_id}/{floor_id}.svg      ← 楼层图纸
floors/{building_id}/{floor_id}.json     ← 映射文件
```

### 3.1 JSON 格式

```json
{
  "floor_id": "b0000000-0000-0000-0000-000000000001",
  "building_id": "a0000000-0000-0000-0000-000000000001",
  "svg_version": "2026-04-08",
  "viewport": {
    "width": 1200,
    "height": 800
  },
  "units": [
    {
      "unit_id": "c0000000-0000-0000-0000-000000000001",
      "unit_number": "101",
      "shape": "rect",
      "bounds": { "x": 120, "y": 50, "width": 200, "height": 150 },
      "label_position": { "x": 220, "y": 125 }
    },
    {
      "unit_id": "c0000000-0000-0000-0000-000000000002",
      "unit_number": "102",
      "shape": "polygon",
      "points": [[330,50], [530,50], [530,200], [330,200]],
      "label_position": { "x": 430, "y": 125 }
    },
    {
      "unit_id": "c0000000-0000-0000-0000-000000000003",
      "unit_number": "103",
      "shape": "path",
      "path_d": "M 540,50 L 740,50 L 740,250 L 640,250 L 640,150 L 540,150 Z",
      "label_position": { "x": 640, "y": 150 }
    }
  ]
}
```

### 3.2 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `unit_id` | UUID | 必须与 `units` 表主键一致 |
| `unit_number` | string | 展示编号 |
| `shape` | `rect` \| `polygon` \| `path` | 形状类型 |
| `bounds` | object | `rect` 专用：`{x, y, width, height}` |
| `points` | number[][] | `polygon` 专用：顶点坐标数组 |
| `path_d` | string | `path` 专用：SVG path `d` 属性 |
| `label_position` | object | 单元编号文字的居中锚点 `{x, y}` |

---

## 四、前端渲染流程

### 4.1 Flutter 移动端（iOS / Android / HarmonyOS Next）

```
1. 通过 WebView 或 canvas 加载 SVG 文件
   - 微信小程序端因原生不支持 SVG，需使用 canvas 降级渲染
2. GET /api/floors/:id/units → 获取该楼层所有单元的 current_status
3. 遍历 SVG DOM 中 [data-unit-id] 元素：
   a. 根据 unit_id 匹配状态
   b. 替换 class → unit-{status}（如 unit-leased / unit-vacant）
4. 绑定点击事件：
   a. 读取 data-unit-id
   b. 弹出单元详情 popup / dialog
```

### 4.2 Admin PC 端（Vue3 + Element Plus）

```
1. 直接内嵌 SVG 到 DOM（v-html 或 <object>）
2. GET /api/floors/:id/units → 获取该楼层所有单元的 current_status
3. 通过 JS 操作 SVG DOM [data-unit-id] 元素，动态切换 class
4. 绑定 @click 事件 → 弹出 ElDialog 单元详情
```

### 状态到 class 映射

| `units.current_status` | SVG class | 对应色彩语义 |
|------------------------|-----------|-------------|
| `leased` | `unit-leased` | success（绿色系）|
| `vacant` | `unit-vacant` | danger（红色系）|
| `expiring_soon` | `unit-expiring-soon` | warning（黄/橙色系）|
| `renovating` | `unit-renovating` | primary（蓝色系）|
| `non_leasable` | `unit-non-leasable` | info（中性灰）|

---

## 五、CAD 转换后处理流程

```
1. ODA File Converter: .dwg → .dxf
2. Python ezdxf: .dxf → .svg（自动生成建筑线稿）
3. 人工标注（或脚本辅助）：
   a. 在 SVG 中框选单元区域
   b. 添加 data-unit-id / data-unit-number 属性
   c. 设置默认 class="unit-vacant"
4. 生成 floor_map.json（从 SVG 热区元素自动提取）
5. 上传至 floors/{building_id}/{floor_id}.svg + .json
```

### 辅助脚本建议

可编写 `scripts/extract_floor_map.py`：

```python
"""从已标注的 SVG 文件提取 floor_map.json"""
# 解析 SVG 中所有 [data-unit-id] 元素
# 提取形状类型、坐标、unit_id
# 输出 floor_map.json
```

---

## 六、校验规则

| 校验项 | 规则 | 触发时机 |
|--------|------|---------|
| unit_id 存在性 | SVG 中每个 `data-unit-id` 必须在 `units` 表中存在 | 上传 SVG 时后端校验 |
| unit_id 唯一性 | 同一 SVG 内不允许重复 `data-unit-id` | 上传时校验 |
| 楼层匹配 | SVG 中的 unit 必须属于该楼层 | 上传时校验 `units.floor_id = 当前楼层` |
| JSON 同步 | `floor_map.json` 与 SVG 热区元素一一对应 | 上传时交叉校验 |
