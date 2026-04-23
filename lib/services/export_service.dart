import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/hotspot.dart';

class ExportResult {
  final String svgPath;
  final String jsonPath;

  const ExportResult({required this.svgPath, required this.jsonPath});
}

class ExportService {
  ExportService._();

  /// Resolve a writable output directory.
  /// Prefers Downloads, falls back to Documents.
  static Future<String> _outputDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  /// Write annotated SVG and floor_map.json to [outputDir].
  /// If [outputDir] is null, falls back to Downloads / Documents.
  ///
  /// Outputs:
  ///   {basename}_hotspot.svg
  ///   {basename}_hotspot.json   (floor_map.json schema)
  static Future<ExportResult> saveExport({
    required String svgContent,
    required List<HotspotModel> hotspots,
    required String sourceFilePath,
    String? outputDir,
    List<Map<String, dynamic>>? unitBounds,
    Map<String, int>? viewport,
  }) async {
    final dir = outputDir ?? await _outputDir();
    final baseName = p.basenameWithoutExtension(sourceFilePath);

    final svgFile = File(p.join(dir, '${baseName}_hotspot.svg'));
    final jsonFile = File(p.join(dir, '${baseName}_hotspot.json'));

    await svgFile.writeAsString(svgContent, flush: true);

    // Build units list from unitBounds (preferred) or fall back to hotspot.toJson()
    final List<Map<String, dynamic>> units;
    if (unitBounds != null && unitBounds.isNotEmpty) {
      units = unitBounds;
    } else {
      // Fallback: emit units without spatial bounds
      units = hotspots
          .map(
            (h) => {
              'unit_id': h.unitId,
              'unit_number': h.unitNumber,
              'shape': 'rect',
              'bounds': null,
              'label_position': null,
            },
          )
          .toList();
    }

    final today = DateTime.now();
    final svgVersion =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final jsonPayload = {
      'floor_id': const Uuid().v4(),
      'building_id': const Uuid().v4(),
      'svg_version': svgVersion,
      'viewport': viewport ?? {'width': 1200, 'height': 800},
      'units': units,
    };

    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(jsonPayload),
      flush: true,
    );

    return ExportResult(svgPath: svgFile.path, jsonPath: jsonFile.path);
  }
}

