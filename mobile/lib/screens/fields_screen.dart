import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../api.dart';
import '../geo.dart';
import '../location.dart';
import '../models.dart';
import '../scouting.dart';
import '../services.dart';
import '../ui/theme.dart';
import '../widgets/sync_button.dart';
import 'field_map_screen.dart';
import 'navigate_screen.dart';

File previewFile(Services s, String fieldId) => File(p.join(s.mapDir.path, '${fieldId}_preview.png'));

/// Fetches the scouting package, NDVI tiles and thumbnail for a field so it works with no signal.
Future<void> downloadForOffline(Services s, String fieldId) async {
  final json = await s.api.scouting(fieldId);
  await s.store.putCache('scouting:$fieldId', json);
  final pkg = ScoutingPackage(json);
  if (pkg.passId == null || pkg.mbtilesPath == null) return;
  if (pkg.previewUrl != null) {
    try {
      final res = await http.get(Uri.parse(pkg.previewUrl!)).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) await previewFile(s, fieldId).writeAsBytes(res.bodyBytes);
    } on Exception {
      // Thumbnail only; the map package below is what matters offline.
    }
  }
  final previous = await s.store.offlineMap(fieldId);
  if (previous?.passId == pkg.passId && File(previous!.path).existsSync()) return;
  final dest = File(p.join(s.mapDir.path, '${fieldId}_${pkg.passId}.mbtiles'));
  await s.api.download(pkg.mbtilesPath!, dest);
  await s.store.putOfflineMap(fieldId, pkg.passId!, dest.path);
  if (previous != null && previous.path != dest.path) {
    final old = File(previous.path);
    if (old.existsSync()) old.deleteSync();
  }
}

/// The next unscouted target across fields, from saved/opened scouting packages.
class _NextTarget {
  _NextTarget(this.field, this.pkg, this.index, this.states);

  final FieldSummary field;
  final ScoutingPackage pkg;
  final int index;
  final Map<String, TargetState> states;
  StressTarget get target => pkg.targets[index];
  int get open => states.values.where((s) => s != TargetState.scouted).length;
}

class FieldsScreen extends StatefulWidget {
  const FieldsScreen({super.key});

  @override
  State<FieldsScreen> createState() => _FieldsScreenState();
}

class _FieldsScreenState extends State<FieldsScreen> {
  List<FieldSummary>? _fields;
  DateTime? _cachedAt; // set when showing cached data because the server was unreachable
  Map<String, String?> _offlinePass = {};
  final Set<String> _downloading = {};
  _NextTarget? _next;
  Position? _me;
  StreamSubscription<Position>? _positions;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fields == null && _error == null) {
      _load();
      _locate();
    }
  }

  @override
  void dispose() {
    _positions?.cancel();
    super.dispose();
  }

  Future<void> _locate() async {
    if (await ensureLocation() != null || !mounted) return;
    _positions = positionStream().listen((p) => setState(() => _me = p), onError: (_) {});
  }

  Future<void> _load() async {
    final s = ServicesScope.of(context);
    try {
      final list = await s.api.fields();
      await s.store.putCache('fields', list);
      _fields = list.map(FieldSummary.new).toList();
      _cachedAt = null;
      _error = null;
    } on AuthExpired {
      await s.signOut();
      return;
    } on Exception catch (e) {
      final cached = await s.store.getCache('fields');
      if (cached != null) {
        _fields = (cached.$1 as List).cast<Map<String, dynamic>>().map(FieldSummary.new).toList();
        _cachedAt = cached.$2;
      } else {
        _error = e is ApiException ? e.message : "Can't reach the server and nothing is saved offline yet.";
      }
    }
    final fields = _fields ?? <FieldSummary>[];
    fields.sort((a, b) => (b.alert ? 1 : 0) - (a.alert ? 1 : 0));
    _offlinePass = {for (final f in fields) f.id: (await s.store.offlineMap(f.id))?.passId};
    _next = await _findNext(s, fields);
    if (mounted) setState(() {});
  }

  Future<_NextTarget?> _findNext(Services s, List<FieldSummary> fields) async {
    for (final f in fields) {
      if (f.zoneCount == 0) continue;
      var json = (await s.store.getCache('scouting:${f.id}'))?.$1 as Map<String, dynamic>?;
      if (json == null && _cachedAt == null) {
        try {
          json = await s.api.scouting(f.id);
          await s.store.putCache('scouting:${f.id}', json);
        } on Exception {
          continue;
        }
      }
      if (json == null) continue;
      final pkg = ScoutingPackage(json);
      final states = targetStates(pkg.targets, await s.store.notes(fieldId: f.id));
      final i = pkg.targets.indexWhere((t) => states[t.zoneId] == TargetState.next);
      if (i >= 0) return _NextTarget(f, pkg, i, states);
    }
    return null;
  }

  Future<void> _download(FieldSummary f) async {
    final s = ServicesScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _downloading.add(f.id));
    try {
      await downloadForOffline(s, f.id);
      messenger.showSnackBar(SnackBar(content: Text('${f.name} is ready for offline use.')));
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: ${e is ApiException ? e.message : 'no connection'}')));
    } finally {
      _downloading.remove(f.id);
      await _load();
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.user?.displayName ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AP.muted)),
                    Text('Fields', style: Theme.of(context).textTheme.headlineMedium),
                  ]),
                ),
                const SyncButton(),
              ]),
              const SizedBox(height: 16),
              ..._body(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_error != null) return [Text(_error!)];
    if (_fields == null) return [const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))];
    return [
      if (_cachedAt != null) ...[_offlineBanner(), const SizedBox(height: 16)],
      if (_next != null) ...[_scoutNext(_next!), const SizedBox(height: 20)],
      Row(children: [
        Text('Your fields', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        const Text('Pull to refresh', style: TextStyle(fontSize: 13, color: AP.muted)),
      ]),
      const SizedBox(height: 12),
      if (_fields!.isEmpty)
        const Text('No fields yet. A farm manager adds them in the web dashboard.')
      else
        for (final f in _fields!) Padding(padding: const EdgeInsets.only(bottom: 12), child: _fieldCard(f)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFB8C4B5), width: 1.5),
        ),
        child: const Row(children: [
          Icon(Icons.download_outlined, color: AP.forest),
          SizedBox(width: 12),
          Expanded(
            child: Text('Save fields for offline before heading out. Maps, zones and targets work with no signal.',
                style: TextStyle(fontSize: 13, color: AP.ink2, height: 1.4)),
          ),
        ]),
      ),
    ];
  }

  Widget _offlineBanner() => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        decoration: BoxDecoration(color: const Color(0xFFFDF1D8), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          const Icon(Icons.cloud_off, size: 20, color: Color(0xFF9A6400)),
          const SizedBox(width: 10),
          Expanded(child: Text('Offline. Showing fields saved ${_ago(_cachedAt!)}.', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );

  Widget _scoutNext(_NextTarget n) {
    final t = n.target;
    String? dist, dir;
    if (_me != null) {
      final d = distanceMeters(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude);
      dist = formatDistance(d);
      dir = compassWords[compassPoint(bearingDegrees(_me!.latitude, _me!.longitude, t.point.latitude, t.point.longitude))];
    }
    return Material(
      color: AP.ink,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: const Key('scout-next'),
        borderRadius: BorderRadius.circular(22),
        onTap: () => _open(NavigateScreen(fieldId: n.field.id, fieldName: n.field.name, targets: n.pkg.targets, states: n.states, initialIndex: n.index)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Text('SCOUT NEXT', style: TextStyle(color: AP.lime, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1)),
              const Spacer(),
              Text('${n.open} open target${n.open == 1 ? '' : 's'}', style: const TextStyle(color: Color(0xFFB9C8BE), fontSize: 12)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Text('${t.rank}', style: const TextStyle(color: AP.ink, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Zone ${t.rank} · ${n.field.name}', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                  Text('NDVI ${t.meanNdvi.toStringAsFixed(2)} · ${(t.areaSqm / 10000).toStringAsFixed(2)} ha',
                      style: AP.monoStyle(13, color: AP.onDark, weight: FontWeight.w400)),
                ]),
              ),
              if (dist != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(dist, style: AP.monoStyle(20, color: Colors.white)),
                  Text(dir!, style: const TextStyle(color: Color(0xFFB9C8BE), fontSize: 12)),
                ]),
            ]),
            const SizedBox(height: 14),
            Container(
              height: 46,
              decoration: BoxDecoration(color: AP.lime, borderRadius: BorderRadius.circular(14)),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.navigation_outlined, color: AP.ink, size: 19),
                SizedBox(width: 8),
                Text('Navigate', style: TextStyle(color: AP.ink, fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _fieldCard(FieldSummary f) {
    final s = ServicesScope.of(context);
    final offline = _offlinePass[f.id];
    final upToDate = offline != null && offline == f.latestPass?['id'];
    final preview = previewFile(s, f.id);
    Widget thumb;
    if (f.latestPass == null) {
      thumb = const Center(child: Icon(Icons.satellite_alt_outlined, color: AP.onDarkMuted));
    } else if (preview.existsSync()) {
      thumb = Image.file(preview, filterQuality: FilterQuality.none, fit: BoxFit.contain);
    } else {
      thumb = Image.network(f.previewUrl!, filterQuality: FilterQuality.none, fit: BoxFit.contain,
          errorBuilder: (_, _, _) => ColoredBox(color: ndviColor(f.meanNdvi ?? 0)));
    }
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: AP.line)),
      child: InkWell(
        key: Key('field-${f.id}'),
        borderRadius: BorderRadius.circular(22),
        onTap: () => _open(FieldMapScreen(fieldId: f.id, title: f.name)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 84,
                height: 84,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AP.mapGround, borderRadius: BorderRadius.circular(14)),
                child: thumb,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(f.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                    if (_downloading.contains(f.id))
                      const Padding(padding: EdgeInsets.all(8), child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)))
                    else if (upToDate)
                      Pill.ok('Offline', key: Key('offline-${f.id}'))
                    else if (f.latestPass != null)
                      IconButton(
                        key: Key('download-${f.id}'),
                        tooltip: offline != null ? 'Update offline copy' : 'Save for offline',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.download_for_offline_outlined, color: AP.forest),
                        onPressed: () => _download(f),
                      ),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '${f.cropType} · ${f.areaHa.toStringAsFixed(1)} ha${f.passDate == null ? '' : ' · pass ${_shortDate(f.passDate!)}'}',
                    style: const TextStyle(fontSize: 13, color: AP.muted),
                  ),
                  if (f.alert) ...[
                    const SizedBox(height: 8),
                    Pill.alert('NDVI fell ${f.meanChange!.abs().toStringAsFixed(2)}'),
                  ],
                ]),
              ),
            ]),
            if (f.latestPass != null) ...[
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: StatTile(value: f.meanNdvi!.toStringAsFixed(2), label: 'Mean NDVI')),
                const SizedBox(width: 8),
                Expanded(child: StatTile(value: '${f.stressedPct!.round()}%', label: 'Stressed')),
                const SizedBox(width: 8),
                Expanded(child: StatTile(value: '${f.scoutedCount} / ${f.zoneCount}', label: 'Scouted')),
              ]),
            ] else ...[
              const SizedBox(height: 10),
              const Text('No satellite pass yet.', style: TextStyle(color: AP.muted)),
            ],
          ]),
        ),
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _shortDate(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day} ${_months[d.month - 1]}';
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
