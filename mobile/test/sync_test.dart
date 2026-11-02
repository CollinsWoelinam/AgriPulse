import 'dart:convert';
import 'dart:io';

import 'package:agripulse_scout/api.dart';
import 'package:agripulse_scout/models.dart';
import 'package:agripulse_scout/store.dart';
import 'package:agripulse_scout/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake server: records accepted note/photo ids; can be switched offline or made to reject requests.
class FakeServer {
  final notes = <String, Map<String, dynamic>>{};
  final photos = <String>{};
  bool offline = false;
  String? rejectCategory; // notes with this category get a 422
  int? photoStatus;
  int requests = 0;

  late final client = MockClient((req) async {
    requests++;
    if (offline) throw const SocketException('no route to host');
    final parts = req.url.pathSegments; // api, notes, {id}[, photos, {photoId}]
    if (req.method == 'PUT' && parts.length == 3 && parts[1] == 'notes') {
      if (jsonDecode(req.body)['category'] == rejectCategory) {
        return http.Response(jsonEncode({'detail': 'rejected'}), 422);
      }
      notes.putIfAbsent(parts[2], () => jsonDecode(req.body));
      return http.Response(jsonEncode({'id': parts[2]}), 200);
    }
    if (req.method == 'PUT' && parts.length == 5 && parts[3] == 'photos') {
      if (photoStatus != null) return http.Response('{}', photoStatus!);
      expect(notes.containsKey(parts[2]), isTrue, reason: 'photo uploaded before its note');
      photos.add(parts[4]);
      return http.Response('{}', 201);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late LocalStore store;
  late FakeServer server;
  late SyncService sync;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('agripulse_sync');
    store = await LocalStore.open(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    server = FakeServer();
    sync = SyncService(store, ApiClient(baseUrl: 'http://test', token: 't', client: server.client));
  });

  tearDown(() async {
    sync.dispose();
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<String> addNote({int photos = 0, String category = 'weeds'}) async {
    final id = 'note-${DateTime.now().microsecondsSinceEpoch}';
    final list = <({String id, String path})>[];
    for (var i = 0; i < photos; i++) {
      final f = File('${tmp.path}/$id-$i.jpg')..writeAsBytesSync([0xff, 0xd8, i, 0xff, 0xd9]);
      list.add((id: '$id-photo-$i', path: f.path));
    }
    await store.addNote(
      LocalNote(id: id, fieldId: 'field-1', lat: 52.54, lon: 5.6, accuracyM: 4, category: category,
          note: 'n', observedAt: DateTime.utc(2026, 11, 2, 10)),
      list,
    );
    return id;
  }

  test('uploads notes, then their photos, and empties the outbox', () async {
    final id = await addNote(photos: 2);
    expect(await store.pendingCount(), 3);

    await sync.syncNow();

    expect(server.notes.keys, [id]);
    expect(server.notes[id]!['observed_at'], '2026-11-02T10:00:00.000Z');
    expect(server.photos, {'$id-photo-0', '$id-photo-1'});
    expect(sync.pending, 0);
    expect(sync.lastError, isNull);
    expect((await store.notes()).single.synced, isTrue);
  });

  test('offline keeps everything queued, and the next sync delivers it', () async {
    await addNote(photos: 1);
    server.offline = true;
    await sync.syncNow();
    expect(sync.pending, 2);
    expect(sync.lastError, contains('Offline'));

    server.offline = false;
    await sync.syncNow();
    expect(sync.pending, 0);
    expect(server.notes, hasLength(1));
    expect(server.photos, hasLength(1));
  });

  test('a photo failure after the note succeeded retries only the photo', () async {
    await addNote(photos: 1);
    server.photoStatus = 503;
    await sync.syncNow();
    expect(server.notes, hasLength(1));
    expect(sync.pending, 1);

    server.photoStatus = null;
    final before = server.requests;
    await sync.syncNow();
    expect(server.requests - before, 1); // just the photo; the note isn't re-sent
    expect(sync.pending, 0);
  });

  test('a rejected note is kept with its error and does not block others', () async {
    server.rejectCategory = 'other';
    final bad = await addNote(category: 'other');
    final good = await addNote();
    await sync.syncNow();

    final notes = {for (final n in await store.notes()) n.id: n};
    expect(notes[bad]!.synced, isFalse);
    expect(notes[bad]!.lastError, 'rejected');
    expect(notes[good]!.synced, isTrue);
  });

  test('expired session stops syncing and flags it', () async {
    await addNote();
    final api = ApiClient(
      baseUrl: 'http://test',
      token: 'old',
      client: MockClient((_) async => http.Response('{"detail":"invalid or expired token"}', 401)),
    );
    final s = SyncService(store, api);
    await s.syncNow();
    expect(s.authExpired, isTrue);
    expect(s.pending, 1);
    s.dispose();
  });

  test('concurrent sync calls share one pass', () async {
    await addNote();
    await Future.wait([sync.syncNow(), sync.syncNow(), sync.syncNow()]);
    expect(server.requests, 1);
  });
}
