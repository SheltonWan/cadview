/// 热区单元候选：来自 Vue `extractUnits` 返回的一条闭合边界。
///
/// 一个 CAD 图层中每条闭合多段线 / Hatch / 圆就是一个 [UnitCandidate]。
library;
import 'package:uuid/uuid.dart';

class UnitBounds {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const UnitBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  double get width => maxX - minX;
  double get height => maxY - minY;

  factory UnitBounds.fromJson(Map<String, dynamic> json) => UnitBounds(
        minX: (json['minX'] as num).toDouble(),
        minY: (json['minY'] as num).toDouble(),
        maxX: (json['maxX'] as num).toDouble(),
        maxY: (json['maxY'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'minX': minX,
        'minY': minY,
        'maxX': maxX,
        'maxY': maxY,
      };
}

class UnitCandidate {
  final int index;
  final UnitBounds bounds;

  /// 自动从标签图层提取的中文/编号文本，可能为空。
  String autoLabel;

  /// 用户填写的单元号（预填 [autoLabel]）。
  String unitNumber;

  /// 状态：vacant / leased / expiring_soon / renovating / non_leasable
  String status;

  /// 分配后的 UUID，对应后端 `units.id`。
  final String unitId;

  /// 是否在导出时包含该单元。
  bool enabled;

  UnitCandidate({
    required this.index,
    required this.bounds,
    required this.autoLabel,
    String? unitId,
    String? unitNumber,
    String status = 'vacant',
    this.enabled = true,
  })  : unitId = unitId ?? const Uuid().v4(),
        unitNumber = unitNumber ?? autoLabel,
        status = status;

  factory UnitCandidate.fromJson(Map<String, dynamic> json) {
    final autoLabel = (json['label'] as String? ?? '').trim();
    return UnitCandidate(
      index: (json['index'] as num?)?.toInt() ?? 0,
      bounds: UnitBounds.fromJson(json['bounds'] as Map<String, dynamic>),
      autoLabel: autoLabel,
    );
  }
}

/// Vue `listUnitSources` 返回的图层统计信息。
class UnitSourceLayer {
  final String name;
  final int closedPolylineCount;
  final int hatchCount;
  final int circleCount;
  final int textCount;
  final int totalEntities;

  const UnitSourceLayer({
    required this.name,
    required this.closedPolylineCount,
    required this.hatchCount,
    required this.circleCount,
    required this.textCount,
    required this.totalEntities,
  });

  /// 边界实体总数（用于判断是否适合作为单元边界来源）。
  int get boundaryCount => closedPolylineCount + hatchCount + circleCount;

  factory UnitSourceLayer.fromJson(Map<String, dynamic> json) => UnitSourceLayer(
        name: json['name'] as String? ?? '',
        closedPolylineCount:
            (json['closedPolylineCount'] as num?)?.toInt() ?? 0,
        hatchCount: (json['hatchCount'] as num?)?.toInt() ?? 0,
        circleCount: (json['circleCount'] as num?)?.toInt() ?? 0,
        textCount: (json['textCount'] as num?)?.toInt() ?? 0,
        totalEntities: (json['totalEntities'] as num?)?.toInt() ?? 0,
      );
}
