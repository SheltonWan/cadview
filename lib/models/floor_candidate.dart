/// 来自 `FlutterBridge` -> `floors_loaded` 的楼层候选信息。
///
/// 多楼层 DWG 常见三种组织方式：
/// * [FloorSource.layout]     —— paper-space 布局 tab（最常见，一个 tab = 一层）
/// * [FloorSource.blockDef]   —— 用户自定义块定义（整张楼层图封装成一个块）
/// * [FloorSource.modelInsert] —— 模型空间里的 `INSERT`，同一块在不同位置被插入
///
/// 三种同时返回，方便用户判断哪一维度对应“楼层”。
enum FloorSource { layout, blockDef, modelInsert }

class FloorBounds {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const FloorBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  double get width => maxX - minX;
  double get height => maxY - minY;

  static FloorBounds? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final minX = (json['minX'] as num?)?.toDouble();
    final minY = (json['minY'] as num?)?.toDouble();
    final maxX = (json['maxX'] as num?)?.toDouble();
    final maxY = (json['maxY'] as num?)?.toDouble();
    if (minX == null || minY == null || maxX == null || maxY == null) return null;
    return FloorBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  @override
  String toString() =>
      '[${minX.toStringAsFixed(1)}, ${minY.toStringAsFixed(1)}] '
      '→ [${maxX.toStringAsFixed(1)}, ${maxY.toStringAsFixed(1)}]';
}

class FloorCandidate {
  final FloorSource source;
  final String name;
  final int entityCount;
  final FloorBounds? bounds;

  /// paper-space layout 的 tab 顺序；其它来源为 0。
  final int tabOrder;

  /// layout 是否当前激活；其它来源为 false。
  final bool isActive;

  /// modelspace 中该块被插入次数（blockDef/modelInsert 有意义）。
  final int insertCount;

  const FloorCandidate({
    required this.source,
    required this.name,
    required this.entityCount,
    this.bounds,
    this.tabOrder = 0,
    this.isActive = false,
    this.insertCount = 0,
  });

  factory FloorCandidate.layout(Map<String, dynamic> json) => FloorCandidate(
        source: FloorSource.layout,
        name: json['name'] as String? ?? '',
        entityCount: (json['entityCount'] as num?)?.toInt() ?? 0,
        bounds: FloorBounds.fromJson(json['extents'] as Map<String, dynamic>?),
        tabOrder: (json['tabOrder'] as num?)?.toInt() ?? 0,
        isActive: json['isActive'] as bool? ?? false,
      );

  factory FloorCandidate.blockDef(Map<String, dynamic> json) => FloorCandidate(
        source: FloorSource.blockDef,
        name: json['name'] as String? ?? '',
        entityCount: (json['entityCount'] as num?)?.toInt() ?? 0,
        bounds: FloorBounds.fromJson(json['extents'] as Map<String, dynamic>?),
        insertCount: (json['insertCount'] as num?)?.toInt() ?? 0,
      );

  factory FloorCandidate.modelInsert(Map<String, dynamic> json) => FloorCandidate(
        source: FloorSource.modelInsert,
        name: json['blockName'] as String? ?? '',
        entityCount: 0,
        insertCount: (json['count'] as num?)?.toInt() ?? 1,
      );
}

/// `floors_loaded` 消息的完整 payload 解码结果。
class FloorCandidateReport {
  final List<FloorCandidate> layouts;
  final List<FloorCandidate> blockDefs;
  final List<FloorCandidate> modelInserts;
  final String activeLayout;

  const FloorCandidateReport({
    required this.layouts,
    required this.blockDefs,
    required this.modelInserts,
    required this.activeLayout,
  });

  factory FloorCandidateReport.fromJson(Map<String, dynamic> json) {
    List<FloorCandidate> decode(
      String key,
      FloorCandidate Function(Map<String, dynamic>) factory,
    ) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw.whereType<Map<String, dynamic>>().map(factory).toList();
    }

    return FloorCandidateReport(
      layouts: decode('layouts', FloorCandidate.layout),
      blockDefs: decode('blockDefs', FloorCandidate.blockDef),
      modelInserts: decode('modelInserts', FloorCandidate.modelInsert),
      activeLayout: json['activeLayout'] as String? ?? '',
    );
  }

  bool get isEmpty =>
      layouts.isEmpty && blockDefs.isEmpty && modelInserts.isEmpty;

  /// 非 `Model` 的 layout 数量 —— 最常见的“每层 = 一个 tab”信号。
  int get nonModelLayoutCount =>
      layouts.where((l) => l.name.toLowerCase() != 'model').length;
}
