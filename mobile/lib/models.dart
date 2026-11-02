import 'package:latlong2/latlong.dart';

class AppUser {
  AppUser({required this.id, required this.email, required this.displayName, required this.role});

  factory AppUser.fromJson(Map<String, dynamic> j) =>
      AppUser(id: j['id'], email: j['email'], displayName: j['display_name'], role: j['role']);

  final String id, email, displayName, role;

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'display_name': displayName, 'role': role};
}

/// Polygon rings of a GeoJSON Polygon or MultiPolygon, as outer rings only (holes are rare for fields).
List<List<LatLng>> outerRings(Map<String, dynamic> geometry) {
  List<LatLng> ring(List coords) => [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())];
  final coords = geometry['coordinates'] as List;
  return switch (geometry['type']) {
    'Polygon' => [ring(coords.first as List)],
    'MultiPolygon' => [for (final poly in coords) ring((poly as List).first as List)],
    _ => const [],
  };
}

class FieldSummary {
  FieldSummary(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'];
  String get name => json['field_name'];
  String get cropType => json['crop_type'];
  double get areaHa => (json['area_hectares'] as num).toDouble();
  Map<String, dynamic>? get latestPass => json['latest_pass'];
  List<List<LatLng>> get rings => outerRings(json['boundary']);
}

class StressTarget {
  StressTarget({required this.zoneId, required this.rank, required this.point, required this.rings,
      required this.meanNdvi, required this.areaSqm});

  final String zoneId;
  final int rank; // 1 = most stressed
  final LatLng point;
  final List<List<LatLng>> rings;
  final double meanNdvi, areaSqm;
}

/// The cached offline package for one field: boundary, latest pass and its stress targets.
class ScoutingPackage {
  ScoutingPackage(this.json);

  final Map<String, dynamic> json;

  FieldSummary get field => FieldSummary(json['field']);
  Map<String, dynamic>? get pass => json['pass'];
  String? get passId => pass?['id'];
  String? get passDate => pass?['acquisition_date'];
  String? get tileUrl => pass?['tile_url'];
  String? get mbtilesPath => json['mbtiles_url'];

  List<StressTarget> get targets {
    final features = (json['zones']?['features'] as List?) ?? const [];
    var rank = 0;
    return [
      for (final f in features)
        StressTarget(
          zoneId: f['id'],
          rank: ++rank,
          point: LatLng(
            (f['properties']['target']['coordinates'][1] as num).toDouble(),
            (f['properties']['target']['coordinates'][0] as num).toDouble(),
          ),
          rings: outerRings(f['geometry']),
          meanNdvi: (f['properties']['mean_ndvi'] as num).toDouble(),
          areaSqm: (f['properties']['area_sqm'] as num).toDouble(),
        ),
    ];
  }
}

const noteCategories = <String, String>{
  'pest_infestation': 'Pest infestation',
  'disease': 'Disease',
  'nitrogen_deficiency': 'Nitrogen deficiency',
  'irrigation_failure': 'Irrigation failure',
  'weeds': 'Weeds',
  'weather_damage': 'Weather damage',
  'no_issue': 'No issue found',
  'other': 'Other',
};

class LocalNote {
  LocalNote({required this.id, required this.fieldId, this.zoneId, required this.lat, required this.lon,
      this.accuracyM, required this.category, required this.note, required this.observedAt,
      this.synced = false, this.lastError, this.photoPaths = const []});

  factory LocalNote.fromRow(Map<String, Object?> r, List<String> photoPaths) => LocalNote(
        id: r['id'] as String,
        fieldId: r['field_id'] as String,
        zoneId: r['zone_id'] as String?,
        lat: r['lat'] as double,
        lon: r['lon'] as double,
        accuracyM: r['accuracy_m'] as double?,
        category: r['category'] as String,
        note: r['note'] as String,
        observedAt: DateTime.parse(r['observed_at'] as String),
        synced: (r['synced'] as int) == 1,
        lastError: r['last_error'] as String?,
        photoPaths: photoPaths,
      );

  final String id, fieldId, category, note;
  final String? zoneId, lastError;
  final double lat, lon;
  final double? accuracyM;
  final DateTime observedAt;
  final bool synced;
  final List<String> photoPaths;

  Map<String, dynamic> toApiJson() => {
        'field_id': fieldId,
        'zone_id': zoneId,
        'lat': lat,
        'lon': lon,
        'accuracy_m': accuracyM,
        'category': category,
        'note': note,
        'observed_at': observedAt.toUtc().toIso8601String(),
      };
}
