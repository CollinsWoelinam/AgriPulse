import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// On-device SQLite: cached server data for offline use, and the outbox of unsynced scouting notes.
class LocalStore {
  LocalStore._(this._db);

  final Database _db;

  static Future<LocalStore> open(String path, {DatabaseFactory? factory}) async {
    final db = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT NOT NULL, updated_at TEXT NOT NULL)');
          await db.execute('''
            CREATE TABLE offline_maps (field_id TEXT PRIMARY KEY, pass_id TEXT NOT NULL, path TEXT NOT NULL,
                                       downloaded_at TEXT NOT NULL)''');
          await db.execute('''
            CREATE TABLE notes (id TEXT PRIMARY KEY, field_id TEXT NOT NULL, zone_id TEXT, lat REAL NOT NULL,
                                lon REAL NOT NULL, accuracy_m REAL, category TEXT NOT NULL, note TEXT NOT NULL,
                                observed_at TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0, last_error TEXT)''');
          await db.execute('''
            CREATE TABLE photos (id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                                 path TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0)''');
        },
      ),
    );
    return LocalStore._(db);
  }

  Future<void> close() => _db.close();

  // ---- Cached server responses ----

  Future<void> putCache(String key, Object json) => _db.insert(
        'cache',
        {'key': key, 'json': jsonEncode(json), 'updated_at': DateTime.now().toUtc().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<(dynamic, DateTime)?> getCache(String key) async {
    final rows = await _db.query('cache', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return (jsonDecode(rows.first['json'] as String), DateTime.parse(rows.first['updated_at'] as String));
  }

  // ---- Offline NDVI maps ----

  Future<void> putOfflineMap(String fieldId, String passId, String path) => _db.insert(
        'offline_maps',
        {'field_id': fieldId, 'pass_id': passId, 'path': path, 'downloaded_at': DateTime.now().toUtc().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<({String passId, String path})?> offlineMap(String fieldId) async {
    final rows = await _db.query('offline_maps', where: 'field_id = ?', whereArgs: [fieldId]);
    if (rows.isEmpty) return null;
    return (passId: rows.first['pass_id'] as String, path: rows.first['path'] as String);
  }

  // ---- Scouting notes outbox ----

  Future<void> addNote(LocalNote n, List<({String id, String path})> photos) => _db.transaction((tx) async {
        await tx.insert('notes', {
          'id': n.id, 'field_id': n.fieldId, 'zone_id': n.zoneId, 'lat': n.lat, 'lon': n.lon,
          'accuracy_m': n.accuracyM, 'category': n.category, 'note': n.note,
          'observed_at': n.observedAt.toUtc().toIso8601String(),
        });
        for (final p in photos) {
          await tx.insert('photos', {'id': p.id, 'note_id': n.id, 'path': p.path});
        }
      });

  Future<List<LocalNote>> notes({String? fieldId}) async {
    final rows = await _db.query('notes',
        where: fieldId == null ? null : 'field_id = ?', whereArgs: fieldId == null ? null : [fieldId],
        orderBy: 'observed_at DESC');
    final photos = await _db.query('photos', orderBy: 'rowid');
    return [
      for (final r in rows)
        LocalNote.fromRow(r, [for (final p in photos) if (p['note_id'] == r['id']) p['path'] as String]),
    ];
  }

  Future<List<LocalNote>> unsyncedNotes() async => (await notes()).where((n) => !n.synced).toList().reversed.toList();

  Future<List<({String id, String noteId, String path})>> unsyncedPhotos() async {
    final rows = await _db.rawQuery('''
      SELECT p.id, p.note_id, p.path FROM photos p JOIN notes n ON n.id = p.note_id
      WHERE p.synced = 0 AND n.synced = 1 ORDER BY p.rowid''');
    return [for (final r in rows) (id: r['id'] as String, noteId: r['note_id'] as String, path: r['path'] as String)];
  }

  Future<int> pendingCount() async => Sqflite.firstIntValue(await _db.rawQuery('''
        SELECT (SELECT count(*) FROM notes WHERE synced = 0) +
               (SELECT count(*) FROM photos WHERE synced = 0)''')) ?? 0;

  Future<void> markNoteSynced(String id) =>
      _db.update('notes', {'synced': 1, 'last_error': null}, where: 'id = ?', whereArgs: [id]);

  Future<void> markNoteError(String id, String error) =>
      _db.update('notes', {'last_error': error}, where: 'id = ?', whereArgs: [id]);

  Future<void> markPhotoSynced(String id) => _db.update('photos', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
}
