import 'package:flutter/material.dart';

import '../models/unit_candidate.dart';

// ─── Status options (shared with hotspot_editor_screen) ───────────────────────

class UnitStatusItem {
  final String value;
  final String label;
  final Color color;
  const UnitStatusItem(this.value, this.label, this.color);
}

const kUnitStatuses = <UnitStatusItem>[
  UnitStatusItem('vacant', '空置', Color(0xFFF44336)),
  UnitStatusItem('leased', '已租', Color(0xFF4CAF50)),
  UnitStatusItem('expiring_soon', '即将到期', Color(0xFFFF9800)),
  UnitStatusItem('renovating', '装修中', Color(0xFF2196F3)),
  UnitStatusItem('non_leasable', '非可租', Color(0xFF9E9E9E)),
];

/// Displays the list of extracted [UnitCandidate] objects (one per closed
/// polyline / hatch / circle on the chosen boundary layer) and lets the user
/// edit `unitNumber` + `status` per unit. Returns the enabled units via
/// [Navigator.pop].
class UnitEditorScreen extends StatefulWidget {
  final List<UnitCandidate> units;
  final String sourceLayerName;
  final List<String> labelLayers;
  final String sourceFileName;

  const UnitEditorScreen({
    super.key,
    required this.units,
    required this.sourceLayerName,
    required this.labelLayers,
    required this.sourceFileName,
  });

  @override
  State<UnitEditorScreen> createState() => _UnitEditorScreenState();
}

class _UnitEditorScreenState extends State<UnitEditorScreen> {
  late List<UnitCandidate> _units;

  @override
  void initState() {
    super.initState();
    _units = widget.units;
  }

  void _export() {
    final missing = <int>[];
    final enabled = _units.where((u) => u.enabled).toList();
    for (final u in enabled) {
      if (u.unitNumber.trim().isEmpty) missing.add(u.index + 1);
    }
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('以下单元未填写编号：${missing.take(6).join("、")}${missing.length > 6 ? "…" : ""}'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    if (enabled.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未勾选任何单元')),
      );
      return;
    }
    Navigator.of(context).pop(enabled);
  }

  void _toggleAll(bool value) {
    setState(() {
      for (final u in _units) {
        u.enabled = value;
      }
    });
  }

  void _bulkSetStatus(String status) {
    setState(() {
      for (final u in _units) {
        if (u.enabled) u.status = status;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final matchedCount = _units.where((u) => u.autoLabel.isNotEmpty).length;
    final enabledCount = _units.where((u) => u.enabled).length;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('单元热区配置 · ${_units.length} 个单元',
                style: const TextStyle(fontSize: 15)),
            Text(
              '${widget.sourceFileName} · 边界图层：${widget.sourceLayerName}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: Text('导出 ($enabledCount)'),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF4FC3F7)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _Toolbar(
            totalCount: _units.length,
            enabledCount: enabledCount,
            matchedCount: matchedCount,
            onToggleAll: _toggleAll,
            onBulkStatus: _bulkSetStatus,
          ),
          const Divider(height: 1, color: Color(0xFF3A3A3A)),
          Expanded(
            child: _units.isEmpty
                ? const Center(
                    child: Text(
                      '图层中未发现闭合边界',
                      style: TextStyle(color: Color(0xFF888888)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _units.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                    itemBuilder: (_, i) {
                      final unit = _units[i];
                      return _UnitTile(
                        unit: unit,
                        onChanged: () => setState(() {}),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final int totalCount;
  final int enabledCount;
  final int matchedCount;
  final ValueChanged<bool> onToggleAll;
  final ValueChanged<String> onBulkStatus;

  const _Toolbar({
    required this.totalCount,
    required this.enabledCount,
    required this.matchedCount,
    required this.onToggleAll,
    required this.onBulkStatus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A2733),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _Stat(label: '总数', value: '$totalCount'),
                _Stat(label: '已启用', value: '$enabledCount', color: const Color(0xFF4FC3F7)),
                _Stat(label: '自动匹配编号', value: '$matchedCount', color: const Color(0xFF81C784)),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onToggleAll(true),
            child: const Text('全选', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => onToggleAll(false),
            child: const Text('全不选', style: TextStyle(fontSize: 12)),
          ),
          PopupMenuButton<String>(
            tooltip: '批量设置状态',
            icon: const Icon(Icons.tune, size: 18, color: Color(0xFF4FC3F7)),
            color: const Color(0xFF2D2D2D),
            onSelected: onBulkStatus,
            itemBuilder: (_) => [
              for (final s in kUnitStatuses)
                PopupMenuItem(
                  value: s.value,
                  child: Row(
                    children: [
                      Container(width: 10, height: 10, color: s.color),
                      const SizedBox(width: 8),
                      Text(s.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Stat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2A36),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ',
              style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 11)),
          Text(
            value,
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitTile extends StatefulWidget {
  final UnitCandidate unit;
  final VoidCallback onChanged;

  const _UnitTile({required this.unit, required this.onChanged});

  @override
  State<_UnitTile> createState() => _UnitTileState();
}

class _UnitTileState extends State<_UnitTile> {
  late final TextEditingController _numCtrl;

  @override
  void initState() {
    super.initState();
    _numCtrl = TextEditingController(text: widget.unit.unitNumber);
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;
    final statusItem = kUnitStatuses.firstWhere(
      (s) => s.value == unit.status,
      orElse: () => kUnitStatuses.first,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      color: unit.enabled ? null : const Color(0xFF181818),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: unit.enabled,
            onChanged: (v) {
              setState(() => unit.enabled = v ?? false);
              widget.onChanged();
            },
            activeColor: const Color(0xFF4FC3F7),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          SizedBox(
            width: 36,
            child: Text(
              '#${unit.index + 1}',
              style: const TextStyle(color: Color(0xFF666666), fontSize: 11),
            ),
          ),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _numCtrl,
              enabled: unit.enabled,
              onChanged: (v) {
                unit.unitNumber = v.trim();
                widget.onChanged();
              },
              style: TextStyle(
                color: unit.enabled ? Colors.white : const Color(0xFF666666),
                fontSize: 13,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                hintText: unit.autoLabel.isNotEmpty ? unit.autoLabel : '单元号',
                hintStyle: const TextStyle(color: Color(0xFF555555), fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: unit.autoLabel.isNotEmpty
                    ? Tooltip(
                        message: '自动识别：${unit.autoLabel}',
                        child: const Icon(Icons.auto_awesome,
                            size: 14, color: Color(0xFF81C784)),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              initialValue: unit.status,
              onChanged: unit.enabled
                  ? (v) {
                      if (v != null) {
                        setState(() => unit.status = v);
                        widget.onChanged();
                      }
                    }
                  : null,
              dropdownColor: const Color(0xFF2D2D2D),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: [
                for (final s in kUnitStatuses)
                  DropdownMenuItem(
                    value: s.value,
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, color: s.color),
                        const SizedBox(width: 6),
                        Text(s.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(
              '${unit.bounds.width.toStringAsFixed(0)}×${unit.bounds.height.toStringAsFixed(0)}',
              style: const TextStyle(color: Color(0xFF666666), fontSize: 10),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 4,
            height: 24,
            decoration: BoxDecoration(
              color: statusItem.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
