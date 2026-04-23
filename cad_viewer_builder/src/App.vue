<template>
  <div class="viewer-root">
    <MlCadViewer
      :url="fileUrl"
      :locale="'zh'"
      :theme="'dark'"
      style="width:100%;height:100%"
    />
    <div v-if="loadError" class="error-overlay">
      <p>{{ loadError }}</p>
      <button @click="loadError = ''">关闭</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { MlCadViewer } from '@mlightcad/cad-viewer'
import { AcApDocManager, AcApConvertToSvgCmd } from '@mlightcad/cad-simple-viewer'
import { acdbHostApplicationServices } from '@mlightcad/data-model'

const fileUrl = ref<string | undefined>(undefined)
const loadError = ref('')

// ─── Helpers ─────────────────────────────────────────────────────────────────

function notifyFlutter(payload: object) {
  try {
    const msg = JSON.stringify(payload)
    if ((window as any).FlutterBridge) {
      ;(window as any).FlutterBridge.postMessage(msg)
    }
  } catch (_) {
    // Running outside Flutter (e.g., browser dev), ignore
  }
}

/** Extract layer list from the currently loaded document and send to Flutter. */
function sendLayerList() {
  try {
    const docManager = AcApDocManager.instance
    const doc = docManager.curDocument
    if (!doc) {
      notifyFlutter({ type: 'debug', payload: 'sendLayerList: no curDocument' })
      return
    }

    const layerTable = doc.database.tables.layerTable
    const layers: object[] = []
    // AcDbObjectIterator implements IterableIterator — use for...of directly
    for (const layer of layerTable.newIterator()) {
      const l = layer as any
      layers.push({
        name: l.name,
        color: l.color?.cssColor ?? '#ffffff',
        isInUse: l.isInUse ?? true,
        isHidden: l.isHidden ?? false,
        isLocked: l.isLocked ?? false,
      })
    }
    notifyFlutter({ type: 'debug', payload: `sendLayerList: found ${layers.length} layers` })
    notifyFlutter({ type: 'layers_loaded', payload: layers })
  } catch (e: any) {
    // Report error back to Flutter so it appears in debug logs
    notifyFlutter({ type: 'debug', payload: `sendLayerList error: ${e?.message ?? e}` })
  }
}

// ─── Floor candidate discovery ────────────────────────────────────────────────
//
// Multi-floor DWGs typically organise per-floor plans using one of three patterns:
//   A) Paper-space LAYOUTS — each tab (e.g. "1F", "2F", "01") is one floor.
//   B) Top-level BLOCK DEFINITIONS — user-defined blocks like "PLAN-01" holding
//      a complete floor plan; inserted once in modelspace.
//   C) Modelspace INSERTs at different positions — floors arranged spatially.
//
// `sendFloorCandidates()` enumerates all three so Flutter can present them and
// the user can pick which dimension maps to "floor" in their file.

interface LayoutInfo {
  name: string
  tabOrder: number
  isActive: boolean
  blockTableRecordId: string
  entityCount: number
  extents: { minX: number; minY: number; maxX: number; maxY: number } | null
}

interface BlockDefInfo {
  name: string
  entityCount: number
  insertCount: number
  extents: { minX: number; minY: number; maxX: number; maxY: number } | null
}

interface ModelInsertInfo {
  blockName: string
  position: { x: number; y: number; z: number }
  layer: string
}

/** True if the block name denotes an anonymous / special / xref block. */
function isSpecialBlockName(name: string): boolean {
  if (!name) return true
  // *MODEL_SPACE, *PAPER_SPACE, *U1, *D1, *E123 etc. are all AutoCAD-internal
  if (name.startsWith('*')) return true
  return false
}

/** Bounding box over all entities in a block table record via `geometricExtents`. */
function computeBtrBbox(btr: any): LayoutInfo['extents'] {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  let count = 0
  try {
    for (const entity of btr.newIterator()) {
      try {
        const ext = (entity as any).geometricExtents
        if (!ext || ext.isEmpty?.()) continue
        const mn = ext.min, mx = ext.max
        if (!mn || !mx) continue
        if (isFinite(mn.x) && isFinite(mn.y) && isFinite(mx.x) && isFinite(mx.y)) {
          if (mn.x < minX) minX = mn.x
          if (mn.y < minY) minY = mn.y
          if (mx.x > maxX) maxX = mx.x
          if (mx.y > maxY) maxY = mx.y
          count++
        }
      } catch { /* entity with no extents — skip */ }
    }
  } catch { /* btr iteration failed */ }
  return count > 0 ? { minX, minY, maxX, maxY } : null
}

/** Count entities in a BTR without caring about extents — fast path. */
function countBtrEntities(btr: any): number {
  let n = 0
  try { for (const _ of btr.newIterator()) n++ } catch { /* ignore */ }
  return n
}

function sendFloorCandidates() {
  try {
    const doc = AcApDocManager.instance.curDocument
    if (!doc) {
      notifyFlutter({ type: 'debug', payload: 'sendFloorCandidates: no curDocument' })
      return
    }

    const db = doc.database
    const blockTable = db.tables.blockTable
    const layoutDict = db.objects.layout
    const activeLayoutName = (() => {
      try { return acdbHostApplicationServices().layoutManager.findActiveLayout() } catch { return '' }
    })()

    // ── Collect modelspace INSERTs indexed by block name ───────────────────
    const insertsByBlock = new Map<string, ModelInsertInfo[]>()
    try {
      const ms = blockTable.modelSpace
      for (const entity of ms.newIterator()) {
        const e = entity as any
        if (e?.type === 'INSERT' || e?.objectName === 'AcDbBlockReference' || typeof e?.blockName === 'string') {
          const name = e.blockName
          if (!name || isSpecialBlockName(name)) continue
          const pos = e.position
          const info: ModelInsertInfo = {
            blockName: name,
            position: {
              x: pos?.x ?? 0,
              y: pos?.y ?? 0,
              z: pos?.z ?? 0,
            },
            layer: e.layer ?? '',
          }
          const arr = insertsByBlock.get(name) ?? []
          arr.push(info)
          insertsByBlock.set(name, arr)
        }
      }
    } catch (e: any) {
      notifyFlutter({ type: 'debug', payload: `floor-inserts: ${e?.message ?? e}` })
    }

    // ── Layouts (paper-space tabs) ─────────────────────────────────────────
    const layouts: LayoutInfo[] = []
    try {
      for (const [, layout] of layoutDict.entries()) {
        const l = layout as any
        const btrId = l.blockTableRecordId
        let entityCount = 0
        let extents: LayoutInfo['extents'] = null
        if (btrId) {
          // Layouts reference a BTR by id; BlockTable doesn't expose a getById directly,
          // so look it up by iterating the block table.
          try {
            for (const btr of blockTable.newIterator()) {
              if ((btr as any).objectId === btrId || (btr as any).id === btrId) {
                entityCount = countBtrEntities(btr)
                extents = computeBtrBbox(btr)
                break
              }
            }
          } catch { /* ignore */ }
        }
        // Fallback to layout's own stored extents if BTR lookup found nothing
        if (!extents) {
          try {
            const lx = l.extents
            if (lx && !lx.isEmpty?.()) {
              extents = {
                minX: lx.min.x, minY: lx.min.y,
                maxX: lx.max.x, maxY: lx.max.y,
              }
            }
          } catch { /* ignore */ }
        }
        layouts.push({
          name: l.layoutName,
          tabOrder: l.tabOrder ?? 0,
          isActive: l.layoutName === activeLayoutName,
          blockTableRecordId: btrId ?? '',
          entityCount,
          extents,
        })
      }
    } catch (e: any) {
      notifyFlutter({ type: 'debug', payload: `floor-layouts: ${e?.message ?? e}` })
    }
    layouts.sort((a, b) => a.tabOrder - b.tabOrder)

    // ── User block definitions (skip model/paper-space & anonymous) ────────
    const blockDefs: BlockDefInfo[] = []
    try {
      for (const btr of blockTable.newIterator()) {
        const b = btr as any
        const name = b.name as string
        if (!name || isSpecialBlockName(name)) continue
        if (b.isModelSapce || b.isPaperSapce) continue
        const entityCount = countBtrEntities(b)
        if (entityCount === 0) continue
        const inserts = insertsByBlock.get(name) ?? []
        blockDefs.push({
          name,
          entityCount,
          insertCount: inserts.length,
          extents: computeBtrBbox(b),
        })
      }
    } catch (e: any) {
      notifyFlutter({ type: 'debug', payload: `floor-blocks: ${e?.message ?? e}` })
    }
    // Sort: blocks that are inserted in modelspace first (more likely to be floors),
    // then by entity count desc.
    blockDefs.sort((a, b) => {
      if (a.insertCount !== b.insertCount) return b.insertCount - a.insertCount
      return b.entityCount - a.entityCount
    })

    // ── Flatten modelspace inserts for reporting ───────────────────────────
    const modelInserts: Array<ModelInsertInfo & { count: number }> = []
    for (const [blockName, arr] of insertsByBlock.entries()) {
      // Emit one aggregated entry per block name with the first insertion point
      modelInserts.push({ ...arr[0], blockName, count: arr.length })
    }
    modelInserts.sort((a, b) => b.count - a.count)

    notifyFlutter({
      type: 'debug',
      payload: `sendFloorCandidates: ${layouts.length} layout(s), ${blockDefs.length} block def(s), ${modelInserts.length} distinct modelspace insert(s)`,
    })
    notifyFlutter({
      type: 'floors_loaded',
      payload: { layouts, blockDefs, modelInserts, activeLayout: activeLayoutName },
    })
  } catch (e: any) {
    notifyFlutter({ type: 'debug', payload: `sendFloorCandidates error: ${e?.message ?? e}` })
  }
}

/** Switch the current layout (paper-space tab) by name. Returns via debug log. */
function switchLayout(name: string) {
  try {
    const ok = acdbHostApplicationServices().layoutManager.setCurrentLayout(name)
    notifyFlutter({ type: 'debug', payload: `switchLayout("${name}") → ${ok}` })
  } catch (e: any) {
    notifyFlutter({ type: 'debug', payload: `switchLayout error: ${e?.message ?? e}` })
  }
}

// ─── Unit extraction (one unit = one closed polyline/hatch/circle) ────────────
//
// Traditional CAD floor plans store each rental unit's boundary as a **closed
// polyline** on a dedicated layer (commonly `SPACE`, `0-面积框线`, `房间`).
// This is the correct granularity for hotspots — treating each CAD *layer* as a
// unit (the old flow) collapses dozens of line-work layers into coarse bboxes.
//
// The two functions below implement the new flow:
//   `listUnitSourceCandidates()` — scan once, rank layers by closed-shape count
//   `extractUnits({ layerName, labelLayers })` — emit one unit per closed shape

interface UnitBbox { minX: number; minY: number; maxX: number; maxY: number }

interface UnitCandidate {
  index: number           // 0-based order of discovery
  bounds: UnitBbox        // DXF-space bbox
  centroid: { x: number; y: number }
  label: string           // auto-matched text, "" if none
}

interface LayerStats {
  name: string
  closedPolylineCount: number
  hatchCount: number
  circleCount: number
  textCount: number
  totalEntities: number
}

/** Returns true when an entity represents a closed boundary we can treat as a unit. */
function isClosedBoundary(entity: any): boolean {
  if (!entity) return false
  const t = (entity.type || entity.objectName || '').toString()
  // mlightcad uses names like 'AcDbPolyline' or 'POLYLINE' depending on context.
  if (t.includes('Polyline') || t === 'POLYLINE' || t === 'LWPOLYLINE') {
    return entity.closed === true
  }
  if (t.includes('Hatch') || t === 'HATCH') return true
  if (t.includes('Circle') || t === 'CIRCLE') return true
  if (t.includes('Ellipse') || t === 'ELLIPSE') return true
  return false
}

function isTextLike(entity: any): boolean {
  if (!entity) return false
  const t = (entity.type || entity.objectName || '').toString()
  return (
    t === 'AcDbText' || t === 'TEXT' ||
    t === 'AcDbMText' || t === 'MTEXT' ||
    t === 'AcDbAttributeDefinition' || t === 'ATTDEF' ||
    t === 'AcDbAttribute' || t === 'ATTRIB'
  )
}

function entityBbox(entity: any): UnitBbox | null {
  try {
    const ext = entity.geometricExtents
    if (!ext || ext.isEmpty?.()) return null
    const mn = ext.min, mx = ext.max
    if (!mn || !mx) return null
    if (!isFinite(mn.x) || !isFinite(mn.y) || !isFinite(mx.x) || !isFinite(mx.y)) return null
    return { minX: mn.x, minY: mn.y, maxX: mx.x, maxY: mx.y }
  } catch { return null }
}

function sendUnitSourceCandidates() {
  try {
    const doc = AcApDocManager.instance.curDocument
    if (!doc) {
      notifyFlutter({
        type: 'export_error',
        payload: '当前没有已加载的 CAD 文档，无法扫描图层',
      })
      return
    }
    const ms = doc.database.tables.blockTable.modelSpace
    const byLayer = new Map<string, LayerStats>()
    const touch = (name: string): LayerStats => {
      let s = byLayer.get(name)
      if (!s) {
        s = { name, closedPolylineCount: 0, hatchCount: 0, circleCount: 0, textCount: 0, totalEntities: 0 }
        byLayer.set(name, s)
      }
      return s
    }
    for (const e of ms.newIterator()) {
      const ent = e as any
      const layer = ent.layer ?? ''
      const stats = touch(layer)
      stats.totalEntities++
      const t = (ent.type || ent.objectName || '').toString()
      if ((t.includes('Polyline') || t === 'POLYLINE' || t === 'LWPOLYLINE') && ent.closed === true) {
        stats.closedPolylineCount++
      } else if (t.includes('Hatch') || t === 'HATCH') {
        stats.hatchCount++
      } else if (t.includes('Circle') || t === 'CIRCLE') {
        stats.circleCount++
      } else if (isTextLike(ent)) {
        stats.textCount++
      }
    }
    const candidates = [...byLayer.values()]
      .filter(s => s.closedPolylineCount + s.hatchCount + s.circleCount > 0 || s.textCount > 0)
      .sort((a, b) => {
        const ascore = a.closedPolylineCount * 3 + a.hatchCount * 2 + a.circleCount
        const bscore = b.closedPolylineCount * 3 + b.hatchCount * 2 + b.circleCount
        return bscore - ascore
      })
    notifyFlutter({
      type: 'debug',
      payload: `unitSources: ${candidates.length} layer(s) with closed/text shapes`,
    })
    notifyFlutter({ type: 'unit_sources_loaded', payload: candidates })
  } catch (e: any) {
    notifyFlutter({
      type: 'export_error',
      payload: `sendUnitSourceCandidates: ${String(e?.message ?? e)}`,
    })
  }
}

function extractUnits(config: { layerName: string; labelLayers?: string[] }) {
  try {
    const { layerName, labelLayers = [] } = config
    const doc = AcApDocManager.instance.curDocument
    if (!doc) {
      notifyFlutter({ type: 'export_error', payload: 'extractUnits: no document' })
      return
    }
    const ms = doc.database.tables.blockTable.modelSpace
    const labelLayerSet = new Set(labelLayers)

    // Collect closed boundaries on the chosen layer
    const units: UnitCandidate[] = []
    // Collect text entities on label layers (for centroid-containment matching)
    const labels: Array<{ x: number; y: number; text: string; layer: string }> = []

    for (const e of ms.newIterator()) {
      const ent = e as any
      const layer = ent.layer ?? ''
      if (layer === layerName && isClosedBoundary(ent)) {
        const b = entityBbox(ent)
        if (!b) continue
        units.push({
          index: units.length,
          bounds: b,
          centroid: { x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2 },
          label: '',
        })
      } else if (labelLayerSet.size > 0 && labelLayerSet.has(layer) && isTextLike(ent)) {
        const pos = ent.position ?? ent.location
        if (!pos) continue
        const text = (ent.textString ?? ent.contents ?? ent.text ?? '').toString().trim()
        if (!text) continue
        labels.push({ x: pos.x, y: pos.y, text, layer })
      }
    }

    // Match: for each label, find the first unit whose bbox contains the label point.
    for (const lbl of labels) {
      for (const u of units) {
        if (u.label) continue
        if (lbl.x >= u.bounds.minX && lbl.x <= u.bounds.maxX &&
            lbl.y >= u.bounds.minY && lbl.y <= u.bounds.maxY) {
          u.label = lbl.text
          break
        }
      }
    }

    notifyFlutter({
      type: 'debug',
      payload: `extractUnits("${layerName}"): ${units.length} unit(s), ${labels.length} label(s), matched ${units.filter(u => u.label).length}`,
    })
    notifyFlutter({
      type: 'units_extracted',
      payload: { layerName, labelLayers, units },
    })
  } catch (e: any) {
    notifyFlutter({ type: 'export_error', payload: `extractUnits: ${String(e?.message ?? e)}` })
  }
}

// ─── SVG export with pre-computed unit bounds ─────────────────────────────────

interface UnitExportConfig {
  unitId: string
  unitNumber: string
  status: string
  /** DXF-space bounds (as returned by extractUnits). */
  bounds: UnitBbox
}

/**
 * Like `exportSvgWithHotspots` but accepts pre-computed DXF-space bounds per unit,
 * so no per-layer SVG re-rendering is needed.
 */
async function exportSvgWithUnits(configJson: string) {
  try {
    const units: UnitExportConfig[] = JSON.parse(configJson)
    notifyFlutter({ type: 'debug', payload: `exportSvgWithUnits: ${units.length} unit(s)` })

    const svgText = await captureSvgText()
    const parser = new DOMParser()
    const svgDoc = parser.parseFromString(svgText, 'image/svg+xml')
    const svgRoot = svgDoc.documentElement

    const vbStr = svgRoot.getAttribute('viewBox') || '0 0 1200 800'
    const vbParts = vbStr.trim().split(/\s+/)
    const viewport = {
      width: Math.round(Math.abs(parseFloat(vbParts[2]))),
      height: Math.round(Math.abs(parseFloat(vbParts[3]))),
    }

    let defs = svgRoot.querySelector('defs')
    if (!defs) {
      defs = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'defs')
      svgRoot.insertBefore(defs, svgRoot.firstChild)
    }
    const styleEl = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'style')
    styleEl.textContent = HOTSPOT_STYLES
    defs.appendChild(styleEl)

    const floorPlan = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'g')
    floorPlan.setAttribute('id', 'floor-plan')
    floorPlan.setAttribute('pointer-events', 'none')
    for (const child of Array.from(svgRoot.children)) {
      if (child.tagName.toLowerCase() !== 'defs') floorPlan.appendChild(child)
    }
    svgRoot.appendChild(floorPlan)

    const hotspotsGroup = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'g')
    hotspotsGroup.setAttribute('id', 'unit-hotspots')
    svgRoot.appendChild(hotspotsGroup)

    const unitBounds: object[] = []
    for (const u of units) {
      const b = u.bounds
      // DXF→SVG Y-flip: same transform as `dxfBboxToSvgRect`
      const rx = Math.round(b.minX)
      const ry = Math.round(-b.maxY)
      const rw = Math.round(b.maxX - b.minX)
      const rh = Math.round(b.maxY - b.minY)

      const rect = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'rect')
      rect.setAttribute('data-unit-id', u.unitId)
      rect.setAttribute('data-unit-number', u.unitNumber)
      rect.setAttribute('class', `unit-${u.status}`)
      rect.setAttribute('x', String(rx))
      rect.setAttribute('y', String(ry))
      rect.setAttribute('width', String(rw))
      rect.setAttribute('height', String(rh))
      hotspotsGroup.appendChild(rect)

      unitBounds.push({
        unit_id: u.unitId,
        unit_number: u.unitNumber,
        shape: 'rect',
        bounds: { x: rx, y: ry, width: rw, height: rh },
        label_position: { x: rx + Math.round(rw / 2), y: ry + Math.round(rh / 2) },
      })
    }

    const resultSvg = new XMLSerializer().serializeToString(svgDoc)
    notifyFlutter({
      type: 'svg_data_with_bounds',
      payload: { svgText: resultSvg, viewport, unitBounds },
    })
  } catch (e: any) {
    notifyFlutter({
      type: 'export_error',
      payload: 'exportSvgWithUnits: ' + String(e?.message ?? e),
    })
  }
}

/**
 * Low-level helper: intercept AcApConvertToSvgCmd to capture the raw SVG text
 * without triggering a browser download.
 */
async function captureSvgText(): Promise<string> {
  const originalCreateObjectURL = URL.createObjectURL.bind(URL)
  let capturedBlob: Blob | null = null

  URL.createObjectURL = (obj: Blob | MediaSource | File) => {
    if (obj instanceof Blob) {
      capturedBlob = obj
      return 'blob:intercepted'
    }
    return originalCreateObjectURL(obj)
  }

  const originalCreateElement = document.createElement.bind(document)
  ;(document as any).createElement = (tagName: string, ...args: any[]) => {
    const el = originalCreateElement(tagName, ...args)
    if (tagName.toLowerCase() === 'a') {
      el.click = () => { /* swallow */ }
      el.appendChild = () => el
      ;(document.body as any).appendChild = (child: any) => {
        if (child === el) return child
        return (document.body as any).__origAppend?.(child) ?? child
      }
    }
    return el
  }

  try {
    const cmd = new AcApConvertToSvgCmd()
    await cmd.execute(AcApDocManager.instance.context as any)
  } finally {
    URL.createObjectURL = originalCreateObjectURL
    ;(document as any).createElement = originalCreateElement
    ;(document.body as any).appendChild =
      (document.body as any).__origAppend ?? document.body.appendChild.bind(document.body)
  }

  if (!capturedBlob) throw new Error('SVG blob not captured')
  return (capturedBlob as Blob).text()
}

/**
 * Export the current drawing as SVG string and send it to Flutter.
 */
async function exportSvg() {
  try {
    const svgText = await captureSvgText()
    notifyFlutter({ type: 'svg_data', payload: svgText })
  } catch (e: any) {
    notifyFlutter({ type: 'export_error', payload: String(e?.message ?? e) })
  }
}

// ─── Hotspot SVG export (SVG_HOTZONE_SPEC v1.0) ───────────────────────────────

/** Standard CSS from SVG_HOTZONE_SPEC §2.2 — injected into <defs><style>. */
const HOTSPOT_STYLES = `
  .unit-leased       { fill: #4CAF50; fill-opacity: 0.35; stroke: #388E3C; stroke-width: 1; }
  .unit-vacant        { fill: #F44336; fill-opacity: 0.35; stroke: #D32F2F; stroke-width: 1; }
  .unit-expiring-soon { fill: #FF9800; fill-opacity: 0.35; stroke: #F57C00; stroke-width: 1; }
  .unit-renovating    { fill: #2196F3; fill-opacity: 0.35; stroke: #1976D2; stroke-width: 1; }
  .unit-non-leasable  { fill: #9E9E9E; fill-opacity: 0.20; stroke: #757575; stroke-width: 1; }
  [data-unit-id]:hover { fill-opacity: 0.55; cursor: pointer; }
`

interface HotspotConfig {
  layerName: string
  unitId: string
  unitNumber: string
  status: string
}

interface DxfBbox { minX: number; minY: number; maxX: number; maxY: number }
interface SvgRect { x: number; y: number; w: number; h: number }

/**
 * Extract the aggregate DXF-space bounding box from all coordinate pairs found
 * in an SVG string. The exported SVG uses a root <g transform="matrix(1,0,0,-1,0,0)">
 * (Y-flip); path coordinates are in DXF (Y-up) space.
 */
function extractSvgDxfBbox(svgText: string): DxfBbox | null {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  let count = 0

  const update = (x: number, y: number) => {
    if (!isFinite(x) || !isFinite(y)) return
    if (x < minX) minX = x
    if (y < minY) minY = y
    if (x > maxX) maxX = x
    if (y > maxY) maxY = y
    count++
  }

  // Comma-separated float pairs — the dominant format in CAD-exported SVG paths
  // e.g. "M2722770.06,-477494.13 L2722770.06,-459994.13"
  const coordPairRe = /([-\d]+(?:\.\d+)?(?:e[+-]?\d+)?),([-\d]+(?:\.\d+)?(?:e[+-]?\d+)?)/g
  let m: RegExpExecArray | null
  while ((m = coordPairRe.exec(svgText)) !== null) {
    update(parseFloat(m[1]), parseFloat(m[2]))
  }

  // Circles: cx, cy, r
  const circleRe = /cx="([-\d.e+]+)"[^>]*?cy="([-\d.e+]+)"[^>]*?r="([-\d.e+]+)"/g
  while ((m = circleRe.exec(svgText)) !== null) {
    const cx = parseFloat(m[1]), cy = parseFloat(m[2]), r = parseFloat(m[3])
    update(cx - r, cy - r)
    update(cx + r, cy + r)
  }

  return count > 0 ? { minX, minY, maxX, maxY } : null
}

/**
 * Convert a DXF-space bbox to an SVG viewBox-space rect.
 * The root <g> has transform="matrix(1,0,0,-1,0,0)", so:
 *   svg_x = dxf_x,  svg_y = -dxf_y
 * For a region [minX, minY, maxX, maxY] in DXF space:
 *   rect = { x: minX, y: -maxY, w: maxX-minX, h: maxY-minY }
 */
function dxfBboxToSvgRect(b: DxfBbox): SvgRect {
  return { x: b.minX, y: -b.maxY, w: b.maxX - b.minX, h: b.maxY - b.minY }
}

/**
 * For each requested layer name:
 *   1. Hide every layer except the target
 *   2. Capture SVG (AcApConvertToSvgCmd respects isHidden)
 *   3. Extract DXF-space bbox → convert to SVG rect
 *   4. Restore all visibilities
 *
 * This is O(n) SVG exports. Typical selections are 5–20 layers, acceptable.
 */
async function computeLayerBoundsViaLayerToggle(
  layerNames: string[],
): Promise<Record<string, SvgRect | null>> {
  const result: Record<string, SvgRect | null> = {}
  const doc = AcApDocManager.instance.curDocument as any
  if (!doc) {
    for (const ln of layerNames) result[ln] = null
    return result
  }

  const layerTable = doc.database.tables.layerTable

  // Save current visibility state
  const savedState = new Map<string, boolean>()
  for (const layer of layerTable.newIterator()) {
    const l = layer as any
    savedState.set(l.name, l.isHidden ?? false)
  }

  try {
    for (const targetLayer of layerNames) {
      notifyFlutter({ type: 'debug', payload: `bbox: scanning "${targetLayer}"` })

      // Show only the target layer
      for (const layer of layerTable.newIterator()) {
        const l = layer as any
        l.isHidden = l.name !== targetLayer
      }

      // Allow one render tick
      await new Promise<void>(resolve => setTimeout(resolve, 120))

      try {
        const svgText = await captureSvgText()
        const dxfBbox = extractSvgDxfBbox(svgText)
        result[targetLayer] = dxfBbox ? dxfBboxToSvgRect(dxfBbox) : null
        notifyFlutter({
          type: 'debug',
          payload: `bbox: "${targetLayer}" → ${JSON.stringify(result[targetLayer])}`,
        })
      } catch (e: any) {
        result[targetLayer] = null
        notifyFlutter({ type: 'debug', payload: `bbox: "${targetLayer}" failed: ${e.message}` })
      }
    }
  } finally {
    // Restore all layer visibilities
    for (const layer of layerTable.newIterator()) {
      const l = layer as any
      if (savedState.has(l.name)) l.isHidden = savedState.get(l.name)!
    }
    notifyFlutter({ type: 'debug', payload: 'bbox: visibility restored' })
  }

  return result
}

/**
 * Build an annotated SVG conforming to SVG_HOTZONE_SPEC v1.0:
 *   <defs><style>   — standard hotspot CSS
 *   <g id="floor-plan">      — wraps the original CAD line art
 *   <g id="unit-hotspots">   — <rect data-unit-id data-unit-number class>
 *
 * Accepts a JSON string: HotspotConfig[]
 * Returns via FlutterBridge: { type: 'svg_data_with_bounds', payload: {...} }
 */
async function exportSvgWithHotspots(configJson: string) {
  try {
    const hotspots: HotspotConfig[] = JSON.parse(configJson)
    notifyFlutter({
      type: 'debug',
      payload: `exportSvgWithHotspots: ${hotspots.length} hotspot(s)`,
    })

    // ── 1. Per-layer bounding boxes ──────────────────────────────────────
    const layerNames = hotspots.map(h => h.layerName)
    const layerBounds = await computeLayerBoundsViaLayerToggle(layerNames)

    // ── 2. Full-drawing SVG (all layers visible after restore) ───────────
    const svgText = await captureSvgText()

    // ── 3. Parse + post-process ──────────────────────────────────────────
    const parser = new DOMParser()
    const svgDoc = parser.parseFromString(svgText, 'image/svg+xml')
    const svgRoot = svgDoc.documentElement

    // Extract viewport
    const vbStr = svgRoot.getAttribute('viewBox') || '0 0 1200 800'
    const vbParts = vbStr.trim().split(/\s+/)
    const viewport = {
      width: Math.round(Math.abs(parseFloat(vbParts[2]))),
      height: Math.round(Math.abs(parseFloat(vbParts[3]))),
    }

    // Inject <defs><style>
    let defs = svgRoot.querySelector('defs')
    if (!defs) {
      defs = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'defs')
      svgRoot.insertBefore(defs, svgRoot.firstChild)
    }
    const styleEl = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'style')
    styleEl.textContent = HOTSPOT_STYLES
    defs.appendChild(styleEl)

    // Wrap existing content into <g id="floor-plan" pointer-events="none">
    const floorPlan = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'g')
    floorPlan.setAttribute('id', 'floor-plan')
    floorPlan.setAttribute('pointer-events', 'none')
    for (const child of Array.from(svgRoot.children)) {
      if (child.tagName.toLowerCase() !== 'defs') floorPlan.appendChild(child)
    }
    svgRoot.appendChild(floorPlan)

    // Create <g id="unit-hotspots">
    const hotspotsGroup = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'g')
    hotspotsGroup.setAttribute('id', 'unit-hotspots')
    svgRoot.appendChild(hotspotsGroup)

    // ── 4. Generate rect elements ────────────────────────────────────────
    const unitBounds: object[] = []

    for (const h of hotspots) {
      const rect = svgDoc.createElementNS('http://www.w3.org/2000/svg', 'rect')
      rect.setAttribute('data-unit-id', h.unitId)
      rect.setAttribute('data-unit-number', h.unitNumber)
      rect.setAttribute('class', `unit-${h.status}`)

      const b = layerBounds[h.layerName]
      if (b) {
        const rx = Math.round(b.x)
        const ry = Math.round(b.y)
        const rw = Math.round(b.w)
        const rh = Math.round(b.h)
        rect.setAttribute('x', String(rx))
        rect.setAttribute('y', String(ry))
        rect.setAttribute('width', String(rw))
        rect.setAttribute('height', String(rh))
        unitBounds.push({
          unit_id: h.unitId,
          unit_number: h.unitNumber,
          shape: 'rect',
          bounds: { x: rx, y: ry, width: rw, height: rh },
          label_position: { x: rx + Math.round(rw / 2), y: ry + Math.round(rh / 2) },
        })
      } else {
        rect.setAttribute('x', '0')
        rect.setAttribute('y', '0')
        rect.setAttribute('width', '0')
        rect.setAttribute('height', '0')
        rect.setAttribute('data-bounds-unavailable', 'true')
        unitBounds.push({
          unit_id: h.unitId,
          unit_number: h.unitNumber,
          shape: 'rect',
          bounds: null,
          label_position: null,
        })
      }
      hotspotsGroup.appendChild(rect)
    }

    // ── 5. Serialize and return ──────────────────────────────────────────
    const resultSvg = new XMLSerializer().serializeToString(svgDoc)
    notifyFlutter({
      type: 'svg_data_with_bounds',
      payload: { svgText: resultSvg, viewport, unitBounds },
    })
  } catch (e: any) {
    notifyFlutter({
      type: 'export_error',
      payload: 'exportSvgWithHotspots: ' + String(e?.message ?? e),
    })
  }
}

/**
 * Debug helper: export SVG then send a compact structural summary to Flutter.
 * Used to inspect the <g> layer grouping produced by AcApConvertToSvgCmd
 * so we can determine how CAD layer names map to SVG element IDs/attributes.
 */
async function dumpSvgStructure() {
  try {
    notifyFlutter({ type: 'debug', payload: 'dumpSvgStructure: capturing SVG…' })
    const svgText = await captureSvgText()

    const parser = new DOMParser()
    const doc = parser.parseFromString(svgText, 'image/svg+xml')
    const root = doc.documentElement

    // Root element attributes (viewBox, width, height, etc.)
    const rootInfo = {
      tag: root.tagName,
      attrs: Object.fromEntries(Array.from(root.attributes).map(a => [a.name, a.value])),
      directChildCount: root.children.length,
      directChildren: Array.from(root.children).slice(0, 20).map(c => ({
        tag: c.tagName,
        id: c.id || null,
        class: c.getAttribute('class') || null,
        childCount: c.children.length,
      })),
    }

    // All <g> elements (up to 60) — key for understanding layer grouping
    const groups = Array.from(doc.querySelectorAll('g')).slice(0, 60).map(g => ({
      id: g.id || null,
      class: g.getAttribute('class') || null,
      // Check common attribute names used for layer identity
      dataLayer: g.getAttribute('data-layer') || null,
      inkscapeLabel: g.getAttribute('inkscape:label') || null,
      title: g.querySelector(':scope > title')?.textContent ?? null,
      allAttrs: Object.fromEntries(Array.from(g.attributes).map(a => [a.name, a.value])),
      childCount: g.children.length,
      childTagSet: [...new Set(Array.from(g.children).map(c => c.tagName))],
    }))

    // First 600 chars of the raw SVG to see the opening structure
    const svgPrefix = svgText.slice(0, 600)

    notifyFlutter({
      type: 'debug',
      payload: '[SVG_STRUCTURE]\n' + JSON.stringify({ svgPrefix, root: rootInfo, groups }, null, 2),
    })
  } catch (e: any) {
    notifyFlutter({ type: 'debug', payload: 'dumpSvgStructure error: ' + String(e?.message ?? e) })
  }
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

onMounted(() => {
  // Expose API for Flutter to call via runJavaScript()
  ;(window as any).cadViewer = {
    /**
     * Load a CAD file from the given URL.
     * Flutter calls: window.cadViewer.loadFile('http://127.0.0.1:{port}/dwg?path=...')
     */
    loadFile(url: string) {
      fileUrl.value = url
    },
    /** Clear the current file. */
    closeFile() {
      fileUrl.value = undefined
    },
    /** Trigger SVG export; result sent via FlutterBridge { type: 'svg_data' | 'export_error' }. */
    exportSvg() {
      exportSvg()
    },
    /**
     * Debug: export SVG and send a compact structural summary via FlutterBridge
     * { type: 'debug', payload: '[SVG_STRUCTURE]\n...' }.
     * Used to inspect how CAD layer names map to SVG element IDs/attributes.
     */
    dumpSvgStructure() {
      dumpSvgStructure()
    },
    /**
     * Export annotated SVG conforming to SVG_HOTZONE_SPEC v1.0.
     * configJson: JSON.stringify(HotspotConfig[])
     * Result via FlutterBridge { type: 'svg_data_with_bounds' | 'export_error' }.
     */
    exportSvgWithHotspots(configJson: string) {
      exportSvgWithHotspots(configJson)
    },
    /**
     * Enumerate floor candidates (layouts / block definitions / modelspace inserts).
     * Result via FlutterBridge { type: 'floors_loaded', payload: {...} }.
     */
    listFloors() {
      sendFloorCandidates()
    },
    /**
     * Switch the current drawing view to the given paper-space layout name.
     * Only meaningful when the file exposes layouts beyond "Model".
     */
    switchLayout(name: string) {
      switchLayout(name)
    },
    /**
     * Rank modelspace layers by count of closed polylines / hatches / circles.
     * Result via FlutterBridge { type: 'unit_sources_loaded', payload: LayerStats[] }.
     */
    listUnitSources() {
      sendUnitSourceCandidates()
    },
    /**
     * Extract one unit per closed boundary on the chosen layer, matching
     * optional text labels from `labelLayers` by centroid containment.
     * configJson: JSON.stringify({ layerName, labelLayers? })
     * Result via FlutterBridge { type: 'units_extracted', payload: {...} }.
     */
    extractUnits(configJson: string) {
      try {
        extractUnits(JSON.parse(configJson))
      } catch (e: any) {
        notifyFlutter({ type: 'export_error', payload: 'extractUnits parse: ' + String(e?.message ?? e) })
      }
    },
    /**
     * Export annotated SVG using pre-computed DXF-space unit bounds.
     * configJson: JSON.stringify(UnitExportConfig[])
     * Result via FlutterBridge { type: 'svg_data_with_bounds' | 'export_error' }.
     */
    exportSvgWithUnits(configJson: string) {
      exportSvgWithUnits(configJson)
    },
  }

  // Listen for document activation to extract layers once the file is parsed
  try {
    AcApDocManager.instance.events.documentActivated.addEventListener(() => {
      // Give the renderer a tick to finalise layer metadata
      setTimeout(sendLayerList, 300)
      setTimeout(sendFloorCandidates, 350)
    })
  } catch (_) {
    // API unavailable in this version; layers will not be sent proactively
  }

  // Notify Flutter that the viewer is ready to receive commands
  notifyFlutter({ type: 'ready' })
})

// Watch fileUrl: when a URL is set, try sendLayerList at multiple intervals
// openProgress never reaches 100% reliably — use timed fallbacks instead
watch(fileUrl, (url) => {
  if (!url) return
  notifyFlutter({ type: 'debug', payload: 'fileUrl changed, scheduling sendLayerList attempts' })
  // Try at 2s, 4s, 8s — stop as soon as layers are found
  let sent = false
  const trySend = (label: string) => {
    if (sent) return
    notifyFlutter({ type: 'debug', payload: `attempting sendLayerList at ${label}` })
    try {
      const doc = AcApDocManager.instance.curDocument
      if (!doc) {
        notifyFlutter({ type: 'debug', payload: `${label}: no curDocument yet` })
        return
      }
      const count = [...doc.database.tables.layerTable.newIterator()].length
      if (count > 0) {
        sent = true
        sendLayerList()
        // Layers are ready → floor metadata (layouts / blocks) is also ready
        sendFloorCandidates()
      } else {
        notifyFlutter({ type: 'debug', payload: `${label}: layerTable empty` })
      }
    } catch (e: any) {
      notifyFlutter({ type: 'debug', payload: `${label} error: ${e?.message ?? e}` })
    }
  }
  setTimeout(() => trySend('2s'), 2000)
  setTimeout(() => trySend('4s'), 4000)
  setTimeout(() => trySend('8s'), 8000)
})
</script>

<style>
html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: #1e1e1e;
}

.viewer-root {
  width: 100%;
  height: 100vh;
  position: relative;
}

.error-overlay {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: rgba(200, 50, 50, 0.9);
  color: white;
  padding: 20px 30px;
  border-radius: 8px;
  text-align: center;
  z-index: 9999;
}

.error-overlay button {
  margin-top: 12px;
  padding: 6px 20px;
  background: white;
  color: #c83232;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}
</style>
