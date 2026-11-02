import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../location.dart';
import '../mbtiles.dart';
import '../models.dart';
import '../services.dart';
import '../widgets/sync_button.dart';
import 'navigate_screen.dart';
import 'note_screen.dart';

const _imageryUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

class FieldMapScreen extends StatefulWidget {
  const FieldMapScreen({super.key, required this.fieldId, required this.title});

  final String fieldId;
  final String title;

  @override
  State<FieldMapScreen> createState() => _FieldMapScreenState();
}

class _FieldMapScreenState extends State<FieldMapScreen> {
  ScoutingPackage? _pkg;
  bool _fromCache = false;
  MbtilesTileProvider? _offlineTiles;
  List<LocalNote> _notes = [];
  Position? _me;
  String? _locationProblem;
  String? _error;
  StreamSubscription<Position>? _positions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pkg == null && _error == null) _load();
  }

  @override
  void dispose() {
    _positions?.cancel();
    _offlineTiles?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = ServicesScope.of(context);
    try {
      final json = await s.api.scouting(widget.fieldId);
      await s.store.putCache('scouting:${widget.fieldId}', json);
      _pkg = ScoutingPackage(json);
    } on AuthExpired {
      await s.signOut();
      return;
    } on Exception catch (e) {
      final cached = await s.store.getCache('scouting:${widget.fieldId}');
      if (cached == null) {
        setState(() => _error = e is ApiException ? e.message : 'No connection, and this field is not saved for offline use.');
        return;
      }
      _pkg = ScoutingPackage(cached.$1 as Map<String, dynamic>);
      _fromCache = true;
    }
    final offline = await s.store.offlineMap(widget.fieldId);
    if (offline != null && offline.passId == _pkg!.passId && File(offline.path).existsSync()) {
      _offlineTiles = await MbtilesTileProvider.open(offline.path);
    }
    await _loadNotes();
    if (mounted) setState(() {});
    _locationProblem = await ensureLocation();
    if (_locationProblem == null) {
      _positions = positionStream().listen((p) => setState(() => _me = p), onError: (_) {});
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadNotes() async {
    _notes = await ServicesScope.of(context).store.notes(fieldId: widget.fieldId);
  }

  Future<void> _openNote({StressTarget? target}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => NoteScreen(fieldId: widget.fieldId, target: target),
    ));
    if (saved == true) {
      await _loadNotes();
      setState(() {});
    }
  }

  Future<void> _navigate(StressTarget t) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NavigateScreen(target: t, onLogObservation: () => _openNote(target: t)),
    ));
    await _loadNotes();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: const [SyncButton()]),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
          : _pkg == null
              ? const Center(child: CircularProgressIndicator())
              : _content(),
    );
  }

  Widget _content() {
    final pkg = _pkg!;
    final targets = pkg.targets;
    final scheme = Theme.of(context).colorScheme;
    final boundary = pkg.field.rings.expand((r) => r).toList();
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.coordinates(coordinates: boundary, padding: const EdgeInsets.fromLTRB(32, 80, 32, 260)),
            maxZoom: 19,
            backgroundColor: const Color(0xFF3A4A3F),
          ),
          children: [
            TileLayer(urlTemplate: _imageryUrl, userAgentPackageName: 'com.agripulse.agripulse_scout', maxNativeZoom: 19),
            if (_offlineTiles != null)
              TileLayer(tileProvider: _offlineTiles!, maxNativeZoom: 17)
            else if (pkg.tileUrl != null)
              TileLayer(urlTemplate: pkg.tileUrl!, userAgentPackageName: 'com.agripulse.agripulse_scout'),
            PolygonLayer(polygons: [
              for (final ring in pkg.field.rings)
                Polygon(points: ring, color: Colors.transparent, borderColor: Colors.white, borderStrokeWidth: 2.5),
              for (final t in targets)
                for (final ring in t.rings)
                  Polygon(points: ring, color: Colors.transparent, borderColor: const Color(0xFFE0452B), borderStrokeWidth: 2),
            ]),
            MarkerLayer(markers: [
              for (final n in _notes)
                Marker(
                  point: LatLng(n.lat, n.lon),
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: n.synced ? const Color(0xFF3EC5F0) : Colors.amber,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0B2530), width: 2),
                    ),
                  ),
                ),
              for (final t in targets)
                Marker(
                  point: t.point,
                  width: 40,
                  height: 40,
                  child: GestureDetector(
                    onTap: () => _navigate(t),
                    child: _TargetBadge(rank: t.rank),
                  ),
                ),
              if (_me != null)
                Marker(
                  point: LatLng(_me!.latitude, _me!.longitude),
                  width: 24,
                  height: 24,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
                    ),
                  ),
                ),
            ]),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('Esri World Imagery'), TextSourceAttribution('Copernicus Sentinel-2')],
            ),
          ],
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.34,
          minChildSize: 0.14,
          maxChildSize: 0.75,
          builder: (context, scroll) => Material(
            elevation: 8,
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: ListView(
              controller: scroll,
              padding: EdgeInsets.zero,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                _statusLine(pkg),
                if (targets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No stress targets in the latest pass.'),
                  ),
                for (final t in targets) _targetTile(t),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusLine(ScoutingPackage pkg) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (pkg.passDate != null) 'Pass ${pkg.passDate}',
      _offlineTiles != null ? 'Map saved offline' : 'Online map',
      if (_fromCache) 'offline copy',
      if (_me != null) 'GPS ±${_me!.accuracy.round()} m',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stress targets', style: theme.textTheme.titleMedium),
                Text('Most stressed first · ${parts.join(' · ')}', style: theme.textTheme.bodySmall),
                if (_locationProblem != null)
                  Text(_locationProblem!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            key: const Key('log-here'),
            onPressed: () => _openNote(),
            icon: const Icon(Icons.add_location_alt),
            label: const Text('Log here'),
          ),
        ],
      ),
    );
  }

  Widget _targetTile(StressTarget t) {
    String? where;
    if (_me != null) {
      final d = distanceMeters(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude);
      final b = bearingDegrees(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude);
      where = '${formatDistance(d)} ${compassPoint(b)}';
    }
    return ListTile(
      key: Key('target-${t.rank}'),
      leading: _TargetBadge(rank: t.rank),
      title: Text('NDVI ${t.meanNdvi.toStringAsFixed(2)} · ${(t.areaSqm / 10000).toStringAsFixed(2)} ha'),
      subtitle: where == null ? null : Text(where),
      trailing: const Icon(Icons.navigation_outlined),
      onTap: () => _navigate(t),
    );
  }
}

class _TargetBadge extends StatelessWidget {
  const _TargetBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFD03B3B),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
        ),
        child: Text('$rank', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
      );
}
