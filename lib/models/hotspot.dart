import 'package:uuid/uuid.dart';

class HotspotModel {
  final String id;
  String name;
  final String layerName;
  Map<String, String> properties;
  String? linkUrl;
  String? action;

  /// Unit identifier (UUID v4, auto-generated, maps to units.id in the backend).
  final String unitId;

  /// Human-readable unit number shown in the floor plan (e.g. "101", "S101").
  String unitNumber;

  /// Current occupancy status — drives the SVG CSS class (unit-{status}).
  /// One of: vacant | leased | expiring_soon | renovating | non_leasable
  String status;

  HotspotModel({
    required this.id,
    required this.name,
    required this.layerName,
    Map<String, String>? properties,
    this.linkUrl,
    this.action,
    String? unitId,
    String? unitNumber,
    String? status,
  }) : properties = properties ?? {},
       unitId = unitId ?? const Uuid().v4(),
       unitNumber = unitNumber ?? '',
       status = status ?? 'vacant';

  factory HotspotModel.fromLayer(String layerName) {
    return HotspotModel(
      id: layerName,
      name: layerName,
      layerName: layerName,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'layerName': layerName,
    'unitId': unitId,
    'unitNumber': unitNumber,
    'status': status,
        'properties': properties,
        if (linkUrl != null && linkUrl!.isNotEmpty) 'linkUrl': linkUrl,
        if (action != null && action!.isNotEmpty) 'action': action,
      };
}
