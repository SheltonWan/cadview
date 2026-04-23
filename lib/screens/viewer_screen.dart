import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import '../models/cad_layer_info.dart';
import '../models/floor_candidate.dart';
import '../models/hotspot.dart';
import '../models/unit_candidate.dart';
import '../services/export_service.dart';
import '../services/local_server.dart';
import 'unit_editor_screen.dart';

class ViewerScreen extends StatefulWidget {
  final String filePath;

  const ViewerScreen({super.key, required this.filePath});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  WebViewController? _controller;
  bool _viewerReady = false;
  bool _serverError = false;
  String? _errorMessage;

  // Hotspot export state
  List<CadLayerInfo> _layerList = [];
  List<HotspotModel>? _pendingHotspots;
  bool _exportingsvg = false;

  // Floor candidate list parsed from the DWG (layouts / block defs / inserts).
  FloorCandidateReport? _floors;

  // Unit extraction flow (closed polyline → unit) ----------------------------
  /// When set, the next `units_extracted` message will trigger navigation to
  /// [UnitEditorScreen] with these remembered layer names.
  _ExtractRequest? _pendingExtract;

  /// Units confirmed by the user in [UnitEditorScreen]; held while Vue
  /// generates the final SVG.
  List<UnitCandidate>? _pendingUnits;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  Future<void> _initViewer() async {
    // Ensure the local HTTP server is running
    try {
      await LocalServer.instance.start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _serverError = true;
          _errorMessage = '无法启动本地服务: $e';
        });
      }
      return;
    }

    final port = LocalServer.instance.port;
    final viewerUrl = 'http://127.0.0.1:$port/viewer/';

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            // Page loaded → load the DWG file
            _loadFile();
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _errorMessage = '页面加载错误: ${error.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(viewerUrl));

    if (mounted) {
      setState(() => _controller = controller);
    }
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'ready') {
        // Vue app is mounted → load the file
        debugPrint('[Bridge] ready received, loading file...');
        setState(() => _viewerReady = true);
        _loadFile();
      } else if (type == 'layers_loaded') {
        final rawList = data['payload'];
        debugPrint(
          '[Bridge] layers_loaded received, count=${rawList is List ? rawList.length : "N/A"}',
        );
        if (rawList is List) {
          final layers = rawList
              .whereType<Map<String, dynamic>>()
              .map(CadLayerInfo.fromJson)
              .toList();
          debugPrint(
            '[Bridge] parsed ${layers.length} layers: ${layers.map((l) => l.name).join(", ")}',
          );
          if (mounted) setState(() => _layerList = layers);
        }
      } else if (type == 'floors_loaded') {
        final payload = data['payload'];
        if (payload is Map<String, dynamic>) {
          final report = FloorCandidateReport.fromJson(payload);
          debugPrint(
            '[Bridge] floors_loaded: layouts=${report.layouts.length}, '
            'blockDefs=${report.blockDefs.length}, '
            'modelInserts=${report.modelInserts.length}, '
            'active="${report.activeLayout}"',
          );
          if (mounted) setState(() => _floors = report);
        }
      } else if (type == 'unit_sources_loaded') {
        final rawList = data['payload'];
        if (rawList is List) {
          final sources = rawList
              .whereType<Map<String, dynamic>>()
              .map(UnitSourceLayer.fromJson)
              .toList();
          debugPrint(
            '[Bridge] unit_sources_loaded: ${sources.length} layer(s)',
          );
          if (mounted) _showUnitSourcePicker(sources);
        }
      } else if (type == 'units_extracted') {
        final payload = data['payload'];
        if (payload is Map<String, dynamic>) {
          final rawUnits = payload['units'];
          final layerName = payload['layerName'] as String? ?? '';
          if (rawUnits is List) {
            final units = rawUnits
                .whereType<Map<String, dynamic>>()
                .map(UnitCandidate.fromJson)
                .toList();
            debugPrint(
              '[Bridge] units_extracted: ${units.length} unit(s) on "$layerName"',
            );
            _onUnitsExtracted(units);
          }
        }
      } else if (type == 'svg_data') {
        final svgContent = data['payload']?.toString() ?? '';
        debugPrint('[Bridge] svg_data received, length=${svgContent.length}');
        _onSvgReceived(svgContent, null, null);
      } else if (type == 'svg_data_with_bounds') {
        final payload = data['payload'] as Map<String, dynamic>?;
        final svgContent = payload?['svgText']?.toString() ?? '';
        final unitBounds = (payload?['unitBounds'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList();
        final viewportRaw = payload?['viewport'] as Map<String, dynamic>?;
        final viewport = viewportRaw == null
            ? null
            : {
                'width': (viewportRaw['width'] as num).toInt(),
                'height': (viewportRaw['height'] as num).toInt(),
              };
        debugPrint(
          '[Bridge] svg_data_with_bounds received, svgLen=${svgContent.length}, units=${unitBounds?.length}',
        );
        _onSvgReceived(svgContent, unitBounds, viewport);
      } else if (type == 'export_error') {
        final msg = data['payload']?.toString() ?? '导出失败';
        if (mounted) {
          setState(() => _exportingsvg = false);
          _showSnackBar('SVG 导出错误: $msg', isError: true);
        }
      } else if (type == 'debug') {
        debugPrint('[Vue] ${data['payload']}');
      } else if (type == 'error') {
        final msg = data['payload']?.toString() ?? '未知错误';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('CAD 错误: $msg'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    } catch (_) {
      // Ignore malformed messages
    }
  }

  void _loadFile() {
    final controller = _controller;
    if (controller == null) return;

    final port = LocalServer.instance.port;
    final encodedPath = Uri.encodeComponent(widget.filePath);
    final fileUrl = 'http://127.0.0.1:$port/dwg?path=$encodedPath';

    _runJs(
      "if (window.cadViewer) { window.cadViewer.loadFile('$fileUrl'); }",
      controller: controller,
    );
  }

  /// Run JS in the webview without propagating the script's return value.
  ///
  /// WKWebView's `runJavaScript` rejects non-serializable return values
  /// (Promises, DOM nodes, etc.), so we wrap every snippet in an IIFE and
  /// explicitly return `null`.
  Future<void> _runJs(String script, {WebViewController? controller}) async {
    final c = controller ?? _controller;
    if (c == null) return;
    final wrapped =
        '(function(){ try { $script } catch(e) { '
        "console.error('[bridge.runJs]', e && e.message || e); "
        '} return null; })();';
    try {
      await c.runJavaScript(wrapped);
    } catch (e) {
      debugPrint('[Bridge] runJavaScript failed: $e');
    }
  }

  Future<void> _openHotspotEditor() async {
    // New flow: ask Vue for unit-source candidates, then pick → extract → edit.
    _runJs('if (window.cadViewer) window.cadViewer.listUnitSources();');
  }

  /// Present the boundary-layer picker once Vue returns candidates.
  Future<void> _showUnitSourcePicker(List<UnitSourceLayer> sources) async {
    if (!mounted) return;
    final pick = await showDialog<_UnitSourcePick>(
      context: context,
      builder: (_) => _UnitSourcePickerDialog(sources: sources),
    );
    if (pick == null || !mounted) return;

    setState(() {
      _pendingExtract = _ExtractRequest(
        boundaryLayer: pick.boundaryLayer,
        labelLayers: pick.labelLayers,
      );
    });

    final config = jsonEncode({
      'layerName': pick.boundaryLayer,
      'labelLayers': pick.labelLayers,
    });
    final escaped = config.replaceAll("'", r"\'");
    _runJs("window.cadViewer.extractUnits('$escaped');");
  }

  Future<void> _onUnitsExtracted(List<UnitCandidate> units) async {
    final request = _pendingExtract;
    if (request == null || !mounted) return;
    setState(() => _pendingExtract = null);

    if (units.isEmpty) {
      _showSnackBar('图层「${request.boundaryLayer}」没有可识别的闭合边界', isError: true);
      return;
    }

    // Show the unit editor — user confirms numbering / status / which units to keep
    final confirmed = await Navigator.of(context).push<List<UnitCandidate>>(
      MaterialPageRoute(
        builder: (_) => UnitEditorScreen(
          units: units,
          sourceLayerName: request.boundaryLayer,
          labelLayers: request.labelLayers,
          sourceFileName: p.basename(widget.filePath),
        ),
      ),
    );
    if (confirmed == null || confirmed.isEmpty || !mounted) return;

    setState(() {
      _pendingUnits = confirmed;
      _exportingsvg = true;
    });

    final config = jsonEncode(
      confirmed
          .map(
            (u) => {
              'unitId': u.unitId,
              'unitNumber': u.unitNumber,
              'status': u.status,
              'bounds': u.bounds.toJson(),
            },
          )
          .toList(),
    );
    final escaped = config.replaceAll("'", r"\'");
    _runJs("window.cadViewer.exportSvgWithUnits('$escaped');");
  }

  Future<void> _onSvgReceived(
    String svgContent,
    List<Map<String, dynamic>>? unitBounds,
    Map<String, int>? viewport,
  ) async {
    final pendingHotspots = _pendingHotspots;
    final pendingUnits = _pendingUnits;
    if (!mounted) return;
    setState(() {
      _exportingsvg = false;
      _pendingHotspots = null;
      _pendingUnits = null;
    });

    if (svgContent.isEmpty) {
      _showSnackBar('SVG 内容为空，导出失败', isError: true);
      return;
    }

    // Prefer unit-based flow; fall back to legacy hotspot flow.
    final hotspotsForExport = pendingUnits != null
        ? pendingUnits
              .map(
                (u) => HotspotModel(
                  id: u.unitId,
                  name: u.unitNumber,
                  layerName: '',
                  unitId: u.unitId,
                  unitNumber: u.unitNumber,
                  status: u.status,
                ),
              )
              .toList()
        : pendingHotspots;

    if (hotspotsForExport == null) {
      _showSnackBar('未知导出来源', isError: true);
      return;
    }

    try {
      // Let user pick output directory
      final outputDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出目录',
      );
      if (outputDir == null) {
        // User cancelled
        if (mounted) _showSnackBar('已取消导出', isError: false);
        return;
      }
      final result = await ExportService.saveExport(
        svgContent: svgContent,
        hotspots: hotspotsForExport,
        sourceFilePath: widget.filePath,
        outputDir: outputDir,
        unitBounds: unitBounds,
        viewport: viewport,
      );
      if (mounted) {
        _showSnackBar('导出成功\nSVG: ${result.svgPath}\nJSON: ${result.jsonPath}');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('写入文件失败: $e', isError: true);
      }
    }
  }

  void _showFloorsSheet() {
    final floors = _floors;
    if (floors == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF252526),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _FloorCandidatesSheet(
        report: floors,
        onSwitchLayout: (name) {
          Navigator.of(ctx).pop();
          _runJs(
            "if (window.cadViewer) { window.cadViewer.switchLayout(${jsonEncode(name)}); }",
          );
          _showSnackBar('切换到布局：$name');
        },
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.red.shade700
            : const Color(0xFF2E7D32),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.filePath);

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 4),
            const Icon(Icons.architecture, size: 18, color: Color(0xFF4FC3F7)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: const TextStyle(fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Floor discovery — show when the DWG has multiple candidates
          if (_floors != null && !_floors!.isEmpty)
            IconButton(
              icon: Badge(
                isLabelVisible:
                    _floors!.nonModelLayoutCount > 0 ||
                    _floors!.blockDefs.isNotEmpty,
                label: Text(
                  '${_floors!.nonModelLayoutCount > 0 ? _floors!.nonModelLayoutCount : _floors!.blockDefs.length}',
                ),
                child: const Icon(Icons.apartment_outlined),
              ),
              tooltip: '楼层解析',
              onPressed: _showFloorsSheet,
            ),
          // Hotspot export button — shown after layers are loaded
          if (_layerList.isNotEmpty)
            _exportingsvg
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF4FC3F7),
                        ),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.layers_outlined),
                    tooltip: '热区图导出',
                    onPressed: _openHotspotEditor,
                  ),
          // Reload button
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载',
            onPressed: _viewerReady ? _loadFile : null,
          ),
          // Debug: inspect SVG layer structure (debug builds only)
          if (kDebugMode && _viewerReady)
            IconButton(
              icon: const Icon(Icons.manage_search, color: Color(0xFFFFB74D)),
              tooltip: '检查 SVG 图层结构（调试）',
              onPressed: () {
                _runJs(
                  'if (window.cadViewer) window.cadViewer.dumpSvgStructure();',
                );
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_serverError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 60, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '启动服务器失败',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.blue),
            SizedBox(height: 16),
            Text(
              '正在启动查看器…',
              style: TextStyle(color: Color(0xFF888888)),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        // Subtle loading overlay until viewer signals ready
        if (!_viewerReady)
          Container(
            color: const Color(0xFF1E1E1E),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF4FC3F7)),
                  SizedBox(height: 16),
                  Text(
                    '正在加载 CAD 文件…',
                    style: TextStyle(color: Color(0xFF888888)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Floor candidate bottom sheet ───────────────────────────────────────────

class _FloorCandidatesSheet extends StatelessWidget {
  final FloorCandidateReport report;
  final void Function(String layoutName) onSwitchLayout;

  const _FloorCandidatesSheet({
    required this.report,
    required this.onSwitchLayout,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade600,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.apartment_outlined, color: Color(0xFF4FC3F7)),
                const SizedBox(width: 8),
                const Text(
                  '楼层候选',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '当前布局：${report.activeLayout.isEmpty ? "未知" : report.activeLayout}',
                  style: const TextStyle(
                    color: Color(0xFF9E9E9E),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                _buildSection(
                  title: '① 布局 (Paper-space Layouts)',
                  hint: '多楼层图纸最常见：每个 tab = 一层楼。点击即可切换查看。',
                  candidates: report.layouts,
                  emptyText: '此图纸不包含布局（只有 Model tab）。',
                  builder: (f) => _LayoutTile(
                    candidate: f,
                    onTap: () => onSwitchLayout(f.name),
                  ),
                ),
                const SizedBox(height: 20),
                _buildSection(
                  title: '② 用户块定义 (Block Definitions)',
                  hint: '若每层是独立块，此处会按「被引用次数」排序。可用于将每层作为独立块导出。',
                  candidates: report.blockDefs,
                  emptyText: '未发现用户自定义块。',
                  builder: (f) => _BlockDefTile(candidate: f),
                ),
                const SizedBox(height: 20),
                _buildSection(
                  title: '③ 模型空间块引用 (Modelspace Inserts)',
                  hint: '模型空间按空间位置插入的不同块。若楼层是空间堆叠，此处可见。',
                  candidates: report.modelInserts,
                  emptyText: '模型空间没有块引用。',
                  builder: (f) => _ModelInsertTile(candidate: f),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required String hint,
    required List<FloorCandidate> candidates,
    required String emptyText,
    required Widget Function(FloorCandidate) builder,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title · ${candidates.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hint,
                  style: const TextStyle(
                    color: Color(0xFF9E9E9E),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF333333)),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                emptyText,
                style: const TextStyle(color: Color(0xFF666666), fontSize: 12),
              ),
            )
          else
            ...candidates.map(builder),
        ],
      ),
    );
  }
}

class _LayoutTile extends StatelessWidget {
  final FloorCandidate candidate;
  final VoidCallback onTap;

  const _LayoutTile({required this.candidate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isModel = candidate.name.toLowerCase() == 'model';
    return ListTile(
      dense: true,
      leading: Icon(
        candidate.isActive
            ? Icons.radio_button_checked
            : (isModel ? Icons.workspaces_outline : Icons.tab_outlined),
        color: candidate.isActive
            ? const Color(0xFF4FC3F7)
            : const Color(0xFF9E9E9E),
        size: 20,
      ),
      title: Text(
        candidate.name,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      subtitle: Text(
        [
          'tab ${candidate.tabOrder}',
          '${candidate.entityCount} 实体',
          if (candidate.bounds != null)
            '尺寸 ${candidate.bounds!.width.toStringAsFixed(0)}×${candidate.bounds!.height.toStringAsFixed(0)}',
        ].join(' · '),
        style: const TextStyle(color: Color(0xFF777777), fontSize: 11),
      ),
      trailing: candidate.isActive
          ? const Chip(
              label: Text('当前', style: TextStyle(fontSize: 10)),
              backgroundColor: Color(0xFF2E7D32),
              labelStyle: TextStyle(color: Colors.white),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity(horizontal: -4, vertical: -4),
            )
          : const Icon(Icons.chevron_right, color: Color(0xFF666666), size: 18),
      onTap: candidate.isActive ? null : onTap,
    );
  }
}

class _BlockDefTile extends StatelessWidget {
  final FloorCandidate candidate;
  const _BlockDefTile({required this.candidate});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(
        Icons.widgets_outlined,
        color: Color(0xFFFFB74D),
        size: 20,
      ),
      title: Text(
        candidate.name,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          '${candidate.entityCount} 实体',
          '被引用 ${candidate.insertCount} 次',
          if (candidate.bounds != null)
            '尺寸 ${candidate.bounds!.width.toStringAsFixed(0)}×${candidate.bounds!.height.toStringAsFixed(0)}',
        ].join(' · '),
        style: const TextStyle(color: Color(0xFF777777), fontSize: 11),
      ),
    );
  }
}

class _ModelInsertTile extends StatelessWidget {
  final FloorCandidate candidate;
  const _ModelInsertTile({required this.candidate});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(
        Icons.place_outlined,
        color: Color(0xFF81C784),
        size: 20,
      ),
      title: Text(
        candidate.name,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '模型空间中插入 ${candidate.insertCount} 次',
        style: const TextStyle(color: Color(0xFF777777), fontSize: 11),
      ),
    );
  }
}

// ─── Unit-source picker (step 1 of hotspot flow) ────────────────────────────

class _ExtractRequest {
  final String boundaryLayer;
  final List<String> labelLayers;
  const _ExtractRequest({
    required this.boundaryLayer,
    required this.labelLayers,
  });
}

class _UnitSourcePick {
  final String boundaryLayer;
  final List<String> labelLayers;
  const _UnitSourcePick({
    required this.boundaryLayer,
    required this.labelLayers,
  });
}

class _UnitSourcePickerDialog extends StatefulWidget {
  final List<UnitSourceLayer> sources;
  const _UnitSourcePickerDialog({required this.sources});

  @override
  State<_UnitSourcePickerDialog> createState() =>
      _UnitSourcePickerDialogState();
}

class _UnitSourcePickerDialogState extends State<_UnitSourcePickerDialog> {
  String? _boundaryLayer;
  final Set<String> _labelLayers = {};

  /// Heuristic: layers whose name hints at being a room label (房号/房间名称/room/text).
  static final _labelPattern = RegExp(
    r'房号|房间|room|name|text|文字',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    // Pre-select the top boundary candidate
    final withBoundaries = widget.sources
        .where((s) => s.boundaryCount > 0)
        .toList();
    if (withBoundaries.isNotEmpty) {
      _boundaryLayer = withBoundaries.first.name;
    }
    // Pre-select up to two text-rich layers that look like labels
    for (final s in widget.sources) {
      if (s.textCount > 0 && _labelPattern.hasMatch(s.name)) {
        _labelLayers.add(s.name);
        if (_labelLayers.length >= 2) break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final boundaryCandidates = widget.sources
        .where((s) => s.boundaryCount > 0)
        .toList();
    final labelCandidates = widget.sources
        .where((s) => s.textCount > 0)
        .toList();

    return Dialog(
      backgroundColor: const Color(0xFF252526),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.crop_landscape,
                    color: Color(0xFF4FC3F7),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '选择单元边界图层',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: const Color(0xFF888888),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '每个闭合多段线 / Hatch / 圆 = 一个单元。选择单元边界所在的图层，'
                '并可选择包含编号文本的图层用于自动填充单元号。',
                style: TextStyle(
                  color: Color(0xFF9E9E9E),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF3A3A3A)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                children: [
                  const _SectionLabel(text: '① 单元边界图层（单选）'),
                  if (boundaryCandidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '未在模型空间中发现闭合多段线 / Hatch / 圆。',
                        style: TextStyle(
                          color: Color(0xFFE57373),
                          fontSize: 12,
                        ),
                      ),
                    )
                  else
                    ...boundaryCandidates.map(
                      (s) => RadioListTile<String>(
                        value: s.name,
                        groupValue: _boundaryLayer,
                        onChanged: (v) => setState(() => _boundaryLayer = v),
                        dense: true,
                        activeColor: const Color(0xFF4FC3F7),
                        title: Text(
                          s.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _subtitleForBoundary(s),
                          style: const TextStyle(
                            color: Color(0xFF777777),
                            fontSize: 11,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 0,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const _SectionLabel(text: '② 编号文本图层（可多选，可选）'),
                  if (labelCandidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '模型空间中未发现文本实体。',
                        style: TextStyle(
                          color: Color(0xFF777777),
                          fontSize: 12,
                        ),
                      ),
                    )
                  else
                    ...labelCandidates.map(
                      (s) => CheckboxListTile(
                        value: _labelLayers.contains(s.name),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _labelLayers.add(s.name);
                          } else {
                            _labelLayers.remove(s.name);
                          }
                        }),
                        dense: true,
                        activeColor: const Color(0xFF4FC3F7),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 0,
                        ),
                        title: Text(
                          s.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${s.textCount} 个文字',
                          style: const TextStyle(
                            color: Color(0xFF777777),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF3A3A3A)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _boundaryLayer == null
                        ? null
                        : () => Navigator.of(context).pop(
                            _UnitSourcePick(
                              boundaryLayer: _boundaryLayer!,
                              labelLayers: _labelLayers.toList(),
                            ),
                          ),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text('提取单元'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0078D4),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitleForBoundary(UnitSourceLayer s) {
    final parts = <String>[];
    if (s.closedPolylineCount > 0) parts.add('${s.closedPolylineCount} 闭合多段线');
    if (s.hatchCount > 0) parts.add('${s.hatchCount} Hatch');
    if (s.circleCount > 0) parts.add('${s.circleCount} 圆');
    parts.add('全图层共 ${s.totalEntities} 实体');
    return parts.join(' · ');
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF4FC3F7),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
