import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../api.dart';
import '../models.dart';
import '../services.dart';
import '../widgets/sync_button.dart';
import 'field_map_screen.dart';

/// Fetches the scouting package and NDVI tiles for a field so it works with no signal.
Future<void> downloadForOffline(Services s, String fieldId) async {
  final json = await s.api.scouting(fieldId);
  await s.store.putCache('scouting:$fieldId', json);
  final pkg = ScoutingPackage(json);
  if (pkg.passId == null || pkg.mbtilesPath == null) return;
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
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fields == null && _error == null) _load();
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
    _offlinePass = {for (final f in _fields ?? <FieldSummary>[]) f.id: (await s.store.offlineMap(f.id))?.passId};
    if (mounted) setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fields'),
        actions: [
          const SyncButton(),
          PopupMenuButton<String>(
            onSelected: (_) => s.signOut(),
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text('${s.user?.displayName} · ${s.user?.role}')),
              const PopupMenuItem(value: 'out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(_error!))]);
    if (_fields == null) return const Center(child: CircularProgressIndicator());
    if (_fields!.isEmpty) {
      return ListView(children: const [
        Padding(padding: EdgeInsets.all(24), child: Text('No fields yet. A farm manager adds them in the web dashboard.')),
      ]);
    }
    return ListView(
      children: [
        if (_cachedAt != null)
          MaterialBanner(
            leading: const Icon(Icons.cloud_off),
            content: Text('Offline. Showing fields saved ${_ago(_cachedAt!)}.'),
            actions: [TextButton(onPressed: _load, child: const Text('Retry'))],
          ),
        for (final f in _fields!) _tile(f),
      ],
    );
  }

  Widget _tile(FieldSummary f) {
    final pass = f.latestPass;
    final theme = Theme.of(context);
    final targets = pass?['stress_zone_count'] ?? 0;
    final offline = _offlinePass[f.id];
    final upToDate = offline != null && offline == pass?['id'];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListTile(
        key: Key('field-${f.id}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        title: Text(f.name, style: theme.textTheme.titleMedium),
        subtitle: Text(pass == null
            ? '${f.cropType} · ${f.areaHa.toStringAsFixed(1)} ha\nNo satellite pass yet'
            : '${f.cropType} · ${f.areaHa.toStringAsFixed(1)} ha · pass ${pass['acquisition_date']}\n'
                '$targets target${targets == 1 ? '' : 's'} · ${pass['stressed_pct']}% stressed'),
        isThreeLine: true,
        trailing: _downloading.contains(f.id)
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))
            : IconButton(
                key: Key('download-${f.id}'),
                tooltip: upToDate ? 'Saved for offline' : offline != null ? 'Update offline copy' : 'Save for offline',
                icon: Icon(upToDate ? Icons.offline_pin : Icons.download_for_offline_outlined,
                    color: upToDate ? theme.colorScheme.primary : null),
                onPressed: pass == null || upToDate ? null : () => _download(f),
              ),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => FieldMapScreen(fieldId: f.id, title: f.name)))
            .then((_) => _load()),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
