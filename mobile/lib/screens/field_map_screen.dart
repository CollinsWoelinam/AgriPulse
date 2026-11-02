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
import '../scouting.dart';
import '../services.dart';
import '../ui/theme.dart';
import '../widgets/sync_button.dart';
import 'navigate_screen.dart';
import 'note_screen.dart';

const _imageryUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class FieldMapScreen extends StatefulWidget {
  const FieldMapScreen({super.key, required this.fieldId, required this.title});

  final String fieldId;
  final String title;

  @override
  State<FieldMapScreen> createState() => _FieldMapScreenState();
}

class _FieldMapScreenState extends State<FieldMapScreen> {
  final _map = MapController();
  ScoutingPackage? _pkg;
  bool _fromCache = false;
  MbtilesTileProvider? _offlineTiles;
  List<LocalNote> _notes = [];
  Map<String, TargetState> _states = {};
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
    _states = targetStates(_pkg!.targets, _notes);
  }

  Future<void> _openNote({StressTarget? target}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => NoteScreen(fieldId: widget.fieldId, fieldName: widget.title, target: target),
    ));
    if (saved == true) {
      await _loadNotes();
      setState(() {});
    }
  }

  Future<void> _navigate(int index) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NavigateScreen(
        fieldId: widget.fieldId, fieldName: widget.title, targets: _pkg!.targets, states: _states, initialIndex: index),
    ));
    await _loadNotes();
    if (mounted) setState(() {});
  }

  StressTarget? get _nextTarget {
    final targets = _pkg?.targets ?? const <StressTarget>[];
    for (final t in targets) {
      if (_states[t.zoneId] == TargetState.next) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(appBar: AppBar(title: Text(widget.title)), body: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_pkg == null) return Scaffold(appBar: AppBar(title: Text(widget.title)), body: const Center(child: CircularProgressIndicator()));
    final pkg = _pkg!;
    final targets = pkg.targets;
    final boundary = pkg.field.rings.expand((r) => r).toList();
    final me = _me == null ? null : LatLng(_me!.latitude, _me!.longitude);
    final next = _nextTarget;
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCameraFit: CameraFit.coordinates(coordinates: boundary, padding: EdgeInsets.fromLTRB(36, topInset + 90, 36, 330)),
            maxZoom: 19,
            backgroundColor: AP.mapGround,
          ),
          children: [
            TileLayer(urlTemplate: _imageryUrl, userAgentPackageName: 'com.agripulse.agripulse_scout', maxNativeZoom: 19),
            if (_offlineTiles != null)
              TileLayer(tileProvider: _offlineTiles!, maxNativeZoom: 17)
            else if (pkg.tileUrl != null)
              TileLayer(urlTemplate: pkg.tileUrl!, userAgentPackageName: 'com.agripulse.agripulse_scout'),
            PolygonLayer(polygons: [
              for (final ring in pkg.field.rings)
                Polygon(points: ring, color: Colors.transparent, borderColor: Colors.white, borderStrokeWidth: 3),
              for (final t in targets)
                for (final ring in t.rings)
                  Polygon(points: ring, color: Colors.transparent, borderColor: AP.zone, borderStrokeWidth: 2.5,
                      pattern: StrokePattern.dashed(segments: const [8, 6])),
            ]),
            if (me != null && next != null)
              PolylineLayer(polylines: [
                Polyline(points: [me, next.point], color: AP.lime, strokeWidth: 3.5, pattern: const StrokePattern.dotted(spacingFactor: 2.5)),
              ]),
            MarkerLayer(markers: [
              for (final n in _notes)
                Marker(
                  point: LatLng(n.lat, n.lon),
                  width: 20,
                  height: 20,
                  child: Container(
                    decoration: BoxDecoration(
                      color: n.synced ? AP.note : AP.pending,
                      shape: BoxShape.circle,
                      border: Border.all(color: AP.noteRing, width: 2.5),
                    ),
                  ),
                ),
              for (final (i, t) in targets.indexed)
                Marker(
                  point: t.point,
                  width: 44,
                  height: 44,
                  child: GestureDetector(
                    onTap: () => _navigate(i),
                    child: Center(
                      child: TargetBadge(rank: t.rank, state: _states[t.zoneId] ?? TargetState.open, onMap: true,
                          size: _states[t.zoneId] == TargetState.next ? 38 : 32),
                    ),
                  ),
                ),
              if (me != null)
                Marker(
                  point: me,
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AP.me,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [BoxShadow(color: AP.me.withValues(alpha: 0.3), spreadRadius: 8)],
                      ),
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

        // Floating top bar
        Positioned(
          left: 16,
          right: 16,
          top: topInset + 8,
          child: Row(children: [
            _RoundButton(icon: Icons.arrow_back, label: 'Back', onTap: () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: AP.ink.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(999)),
                child: Row(children: [
                  Flexible(child: Text(widget.title, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800))),
                  if (pkg.passDate != null) ...[
                    const SizedBox(width: 8),
                    Text(_short(pkg.passDate!), style: AP.monoStyle(12, color: const Color(0xFFB9C8BE), weight: FontWeight.w400)),
                  ],
                ]),
              ),
            ),
            const SizedBox(width: 10),
            const SyncButton(onDark: true),
          ]),
        ),
        if (_offlineTiles != null || _fromCache)
          Positioned(
            left: 16,
            top: topInset + 62,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: AP.ink.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_fromCache ? Icons.cloud_off : Icons.check, size: 13, color: AP.lime),
                const SizedBox(width: 6),
                Text(_fromCache ? 'Offline copy' : 'Saved offline',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),

        // Bottom sheet with targets
        DraggableScrollableSheet(
          initialChildSize: 0.42,
          minChildSize: 0.16,
          maxChildSize: 0.8,
          builder: (context, scroll) => Container(
            decoration: const BoxDecoration(
              color: AP.bg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, -10))],
            ),
            child: ListView(
              controller: scroll,
              padding: EdgeInsets.zero,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(0, 10, 0, 6),
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(color: const Color(0xFFC9D0C3), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Stress targets', style: Theme.of(context).textTheme.titleLarge),
                        Text(
                          ['Most stressed first', if (_me != null) 'GPS ±${_me!.accuracy.round()} m'].join(' · '),
                          style: const TextStyle(fontSize: 12, color: AP.muted),
                        ),
                        if (_locationProblem != null)
                          Text(_locationProblem!, style: const TextStyle(fontSize: 12, color: AP.alert)),
                      ]),
                    ),
                    FilledButton.icon(
                      key: const Key('log-here'),
                      onPressed: () => _openNote(),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(fontFamily: AP.sans, fontSize: 14, fontWeight: FontWeight.w800),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      icon: const Icon(Icons.add, color: AP.lime, size: 18),
                      label: const Text('Log here'),
                    ),
                  ]),
                ),
                if (targets.isEmpty)
                  const Padding(padding: EdgeInsets.all(20), child: Text('No stress targets in the latest pass.')),
                for (final (i, t) in targets.indexed) _targetRow(t, i),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        if (me != null)
          Positioned(
            right: 16,
            bottom: MediaQuery.sizeOf(context).height * 0.42 + 12,
            child: _RoundButton(icon: Icons.my_location, label: 'Centre on me', color: AP.me,
                onTap: () => _map.move(me, _map.camera.zoom < 16 ? 17 : _map.camera.zoom)),
          ),
      ]),
    );
  }

  Widget _targetRow(StressTarget t, int i) {
    final state = _states[t.zoneId] ?? TargetState.open;
    String? dist, dir;
    if (_me != null) {
      dist = formatDistance(distanceMeters(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude));
      dir = compassPoint(bearingDegrees(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude));
    }
    final status = switch (state) { TargetState.scouted => 'Scouted', TargetState.next => 'Next up', _ => 'Not scouted' };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('target-${t.rank}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => _navigate(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              TargetBadge(rank: t.rank, state: state),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: 'NDVI '),
                    TextSpan(text: t.meanNdvi.toStringAsFixed(2), style: AP.monoStyle(14)),
                    const TextSpan(text: ' · '),
                    TextSpan(text: (t.areaSqm / 10000).toStringAsFixed(2), style: AP.monoStyle(14)),
                    const TextSpan(text: ' ha'),
                  ]), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  Text(status, style: TextStyle(fontSize: 12, color: state == TargetState.scouted ? AP.forest : AP.muted,
                      fontWeight: state == TargetState.next ? FontWeight.w700 : FontWeight.w500)),
                ]),
              ),
              if (dist != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(dist, style: AP.monoStyle(15)),
                  Text(dir!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AP.muted)),
                ]),
            ]),
          ),
        ),
      ),
    );
  }
}

String _short(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day} ${_months[d.month - 1]}';
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onTap, this.color = AP.ink});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 4,
        child: IconButton(tooltip: label, icon: Icon(icon, color: color, size: 22), onPressed: onTap),
      );
}
