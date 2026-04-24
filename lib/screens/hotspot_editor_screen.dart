import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/cad_layer_info.dart';
import '../models/hotspot.dart';

// ─── Status options ───────────────────────────────────────────────────────────

class _StatusItem {
  final String value;
  final String label;
  final Color color;
  const _StatusItem(this.value, this.label, this.color);
}

const _kUnitStatuses = [
  _StatusItem('vacant', '空置', Color(0xFFF44336)),
  _StatusItem('leased', '已租', Color(0xFF4CAF50)),
  _StatusItem('expiring_soon', '即将到期', Color(0xFFFF9800)),
  _StatusItem('renovating', '装修中', Color(0xFF2196F3)),
  _StatusItem('non_leasable', '非可租', Color(0xFF9E9E9E)),
];

/// Displays the list of CAD layers and lets the user configure each one
/// as a hotspot with a name, custom properties, and an optional link/action.
///
/// When the user taps "导出", all enabled hotspots are popped back to the caller.
class HotspotEditorScreen extends StatefulWidget {
  final List<CadLayerInfo> layers;
  final String sourceFileName;

  const HotspotEditorScreen({
    super.key,
    required this.layers,
    required this.sourceFileName,
  });

  @override
  State<HotspotEditorScreen> createState() => _HotspotEditorScreenState();
}

class _HotspotEditorScreenState extends State<HotspotEditorScreen> {
  // Map layerName → enabled flag
  late final Map<String, bool> _enabled;
  // Map layerName → HotspotModel (mutable)
  late final Map<String, HotspotModel> _hotspots;

  @override
  void initState() {
    super.initState();
    _enabled = {};
    _hotspots = {};

    for (final layer in widget.layers) {
      final enable = layer.isInUse && !layer.isHidden;
      _enabled[layer.name] = enable;
      _hotspots[layer.name] = HotspotModel.fromLayer(layer.name);
    }
  }

  void _export() {
    // Validate that every enabled hotspot has a unit number
    final missing = <String>[];
    for (final layer in widget.layers) {
      if (_enabled[layer.name] == true) {
        if (_hotspots[layer.name]!.unitNumber.isEmpty) {
          missing.add(layer.name);
        }
      }
    }
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请填写单元编号：${missing.join('、')}'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    final result = <HotspotModel>[];
    for (final layer in widget.layers) {
      if (_enabled[layer.name] == true) {
        result.add(_hotspots[layer.name]!);
      }
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('热区配置', style: TextStyle(fontSize: 16)),
            Text(
              widget.sourceFileName,
              style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('生成热区图'),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF4FC3F7)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: widget.layers.isEmpty
          ? const Center(
              child: Text(
                '未检测到图层',
                style: TextStyle(color: Color(0xFF888888)),
              ),
            )
          : Column(
              children: [
                _InfoBanner(),
                const Divider(height: 1, color: Color(0xFF3A3A3A)),
                Expanded(
                  child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.layers.length,
                    separatorBuilder: (context, _) =>
                        const Divider(
                height: 1,
                color: Color(0xFF3A3A3A),
              ),
              itemBuilder: (context, index) {
                final layer = widget.layers[index];
                return _LayerHotspotTile(
                  layer: layer,
                  enabled: _enabled[layer.name] ?? false,
                  hotspot: _hotspots[layer.name]!,
                  onEnabledChanged: (v) =>
                      setState(() => _enabled[layer.name] = v),
                  onHotspotChanged: () => setState(() {}),
                );
              },
            ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF1A2733),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 15,
                color: Color(0xFF4FC3F7),
              ),
              const SizedBox(width: 6),
              const Text(
                '操作步骤',
                style: TextStyle(
                  color: Color(0xFF4FC3F7),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _StepRow(step: '1', text: '打开开关，将图层设为可点击的热区区域'),
          const SizedBox(height: 4),
          const _StepRow(step: '2', text: '点击图层名展开，填写铺位编号（如 101）和租赁状态'),
          const SizedBox(height: 4),
          const _StepRow(step: '3', text: '所有编号填完后，点击右上角「生成热区图」导出'),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String step;
  final String text;
  const _StepRow({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: const BoxDecoration(
            color: Color(0xFF2A4A66),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            step,
            style: const TextStyle(color: Color(0xFF4FC3F7), fontSize: 11),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFAABBCC),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _LayerHotspotTile extends StatelessWidget {
  final CadLayerInfo layer;
  final bool enabled;
  final HotspotModel hotspot;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onHotspotChanged;

  const _LayerHotspotTile({
    required this.layer,
    required this.enabled,
    required this.hotspot,
    required this.onEnabledChanged,
    required this.onHotspotChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: enabled,
              onChanged: onEnabledChanged,
              activeThumbColor: const Color(0xFF4FC3F7),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            _ColorDot(cssColor: layer.color),
          ],
        ),
        title: Text(
          layer.name,
          style: TextStyle(
            color: enabled ? Colors.white : const Color(0xFF666666),
            fontSize: 14,
          ),
        ),
        subtitle: _buildSubtitle(),

        collapsedIconColor: const Color(0xFF888888),
        iconColor: const Color(0xFF4FC3F7),
        children: enabled
            ? [_HotspotForm(hotspot: hotspot, onChanged: onHotspotChanged)]
            : [],
      ),
    );
  }

  Widget? _buildSubtitle() {
    final badges = <Widget>[];
    if (layer.isHidden) {
      badges.add(const _Badge(label: '图层隐藏', color: Color(0xFF666666)));
    }
    if (layer.isLocked) {
      if (badges.isNotEmpty) badges.add(const SizedBox(width: 4));
      badges.add(const _Badge(label: '图层锁定', color: Color(0xFF886644)));
    }
    if (enabled) {
      final unitNum = hotspot.unitNumber.isNotEmpty ? hotspot.unitNumber : null;
      final statusLabel = _kUnitStatuses
          .firstWhere(
            (s) => s.value == hotspot.status,
            orElse: () => _kUnitStatuses.first,
          )
          .label;
      final info = unitNum != null ? '$unitNum · $statusLabel' : '点击展开，填写铺位编号';
      if (badges.isEmpty) {
        return Text(
          info,
          style: TextStyle(
            color: unitNum != null
                ? const Color(0xFF4FC3F7)
                : const Color(0xFFFF9800),
            fontSize: 11,
          ),
        );
      } else {
        badges.addAll([
          const SizedBox(width: 4),
          Text(
            info,
            style: const TextStyle(color: Color(0xFF4FC3F7), fontSize: 11),
          ),
        ]);
      }
    }
    if (badges.isEmpty) return null;
    return Row(children: badges);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _HotspotForm extends StatefulWidget {
  final HotspotModel hotspot;
  final VoidCallback onChanged;

  const _HotspotForm({required this.hotspot, required this.onChanged});

  @override
  State<_HotspotForm> createState() => _HotspotFormState();
}

class _HotspotFormState extends State<_HotspotForm> {
  late final TextEditingController _unitNumberCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _linkCtrl;
  late final TextEditingController _actionCtrl;
  late String _statusValue;
  final List<_PropEntry> _propEntries = [];

  @override
  void initState() {
    super.initState();
    _unitNumberCtrl = TextEditingController(text: widget.hotspot.unitNumber);
    _statusValue = widget.hotspot.status;
    _nameCtrl = TextEditingController(text: widget.hotspot.name);
    _linkCtrl = TextEditingController(text: widget.hotspot.linkUrl ?? '');
    _actionCtrl = TextEditingController(text: widget.hotspot.action ?? '');
    for (final entry in widget.hotspot.properties.entries) {
      _propEntries.add(
        _PropEntry(
          keyCtrl: TextEditingController(text: entry.key),
          valueCtrl: TextEditingController(text: entry.value),
        ),
      );
    }
  }

  @override
  void dispose() {
    _unitNumberCtrl.dispose();
    _nameCtrl.dispose();
    _linkCtrl.dispose();
    _actionCtrl.dispose();
    for (final e in _propEntries) {
      e.dispose();
    }
    super.dispose();
  }

  void _sync() {
    widget.hotspot.unitNumber = _unitNumberCtrl.text.trim();
    widget.hotspot.status = _statusValue;
    widget.hotspot.name = _nameCtrl.text.trim().isEmpty
        ? widget.hotspot.layerName
        : _nameCtrl.text.trim();
    widget.hotspot.linkUrl = _linkCtrl.text.trim();
    widget.hotspot.action = _actionCtrl.text.trim();
    widget.hotspot.properties = {
      for (final e in _propEntries)
        if (e.keyCtrl.text.trim().isNotEmpty)
          e.keyCtrl.text.trim(): e.valueCtrl.text.trim()
    };
    widget.onChanged();
  }

  void _addProp() {
    setState(() {
      _propEntries.add(
        _PropEntry(
          keyCtrl: TextEditingController(),
          valueCtrl: TextEditingController(),
        ),
      );
    });
  }

  void _removeProp(int index) {
    setState(() {
      _propEntries[index].dispose();
      _propEntries.removeAt(index);
    });
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 铺位编号（必填）────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                '铺位编号',
                style: TextStyle(color: Color(0xFF888888), fontSize: 11),
              ),
              const SizedBox(width: 4),
              const Text(
                '必填',
                style: TextStyle(color: Color(0xFFF44336), fontSize: 10),
              ),
              const Spacer(),
              const Text(
                '显示在平面图热区上',
                style: TextStyle(color: Color(0xFF555555), fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _InlineField(
            controller: _unitNumberCtrl,
            hint: '例如：101、A-02、S101',
            onChanged: (_) => _sync(),
          ),
          const SizedBox(height: 10),

          // ── 状态选择 ───────────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                '租赁状态',
                style: TextStyle(color: Color(0xFF888888), fontSize: 11),
              ),
              const Spacer(),
              const Text(
                '决定热区颜色',
                style: TextStyle(color: Color(0xFF555555), fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 4),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _statusValue,
              isExpanded: true,
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: _kUnitStatuses
                  .map(
                    (s) => DropdownMenuItem(
                      value: s.value,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: s.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(s.label),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _statusValue = v);
                _sync();
              },
            ),
          ),
          const SizedBox(height: 10),

          // ── Unit ID（只读 + 复制）──────────────────────────────────────────
          Row(
            children: [
              const Text(
                '系统 ID',
                style: TextStyle(color: Color(0xFF888888), fontSize: 11),
              ),
              const Spacer(),
              const Text(
                '自动生成，无需修改',
                style: TextStyle(color: Color(0xFF555555), fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.hotspot.unitId,
                  style: const TextStyle(
                    color: Color(0xFF666666),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.copy,
                  size: 14,
                  color: Color(0xFF555555),
                ),
                tooltip: '复制 ID',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.hotspot.unitId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Unit ID 已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── 高级设置（折叠） ───────────────────────────────────────────────
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text(
                '高级设置',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
              iconColor: const Color(0xFF555555),
              collapsedIconColor: const Color(0xFF555555),
              children: [
                _FormField(
                  label: '热区名称',
                  controller: _nameCtrl,
                  onChanged: (_) => _sync(),
                ),
                const SizedBox(height: 10),
                _FormField(
                  label: '链接 URL',
                  controller: _linkCtrl,
                  hint: 'https://example.com',
                  onChanged: (_) => _sync(),
                ),
                const SizedBox(height: 10),
                _FormField(
                  label: '动作 (Action)',
                  controller: _actionCtrl,
                  hint: '例如：open_detail_panel',
                  onChanged: (_) => _sync(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      '自定义属性',
                      style: TextStyle(color: Color(0xFF888888), fontSize: 12),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addProp,
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('添加', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF4FC3F7),
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ..._propEntries.asMap().entries.map(
                  (entry) => _PropRow(
                    propEntry: entry.value,
                    onRemove: () => _removeProp(entry.key),
                    onChanged: (_) => _sync(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PropEntry {
  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;

  _PropEntry({required this.keyCtrl, required this.valueCtrl});

  void dispose() {
    keyCtrl.dispose();
    valueCtrl.dispose();
  }
}

class _PropRow extends StatelessWidget {
  final _PropEntry propEntry;
  final VoidCallback onRemove;
  final void Function(String) onChanged;

  const _PropRow({
    required this.propEntry,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: _InlineField(
              controller: propEntry.keyCtrl,
              hint: '键',
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _InlineField(
              controller: propEntry.valueCtrl,
              hint: '值',
              onChanged: onChanged,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Color(0xFF666666)),
            onPressed: onRemove,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _FormField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final void Function(String) onChanged;

  const _FormField({
    required this.label,
    required this.controller,
    this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(color: Color(0xFF888888), fontSize: 11)),
        const SizedBox(height: 4),
        _InlineField(
            controller: controller, hint: hint, onChanged: onChanged),
      ],
    );
  }
}

class _InlineField extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final void Function(String) onChanged;

  const _InlineField({
    required this.controller,
    this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF555555), fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: Color(0xFF444444)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: Color(0xFF444444)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: Color(0xFF4FC3F7)),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final String cssColor;

  const _ColorDot({required this.cssColor});

  @override
  Widget build(BuildContext context) {
    Color color;
    try {
      final hex = cssColor.replaceFirst('#', '');
      color = Color(int.parse(
        hex.length == 6 ? 'FF$hex' : hex,
        radix: 16,
      ));
    } catch (_) {
      color = Colors.white;
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF555555), width: 0.5),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(50),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }
}
