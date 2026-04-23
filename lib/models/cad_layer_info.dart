class CadLayerInfo {
  final String name;
  final String color;
  final bool isInUse;
  final bool isHidden;
  final bool isLocked;

  const CadLayerInfo({
    required this.name,
    required this.color,
    this.isInUse = false,
    this.isHidden = false,
    this.isLocked = false,
  });

  factory CadLayerInfo.fromJson(Map<String, dynamic> json) {
    return CadLayerInfo(
      name: json['name'] as String? ?? '',
      color: json['color'] as String? ?? '#ffffff',
      isInUse: json['isInUse'] as bool? ?? false,
      isHidden: json['isHidden'] as bool? ?? false,
      isLocked: json['isLocked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'color': color,
        'isInUse': isInUse,
        'isHidden': isHidden,
        'isLocked': isLocked,
      };
}
