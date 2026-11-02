import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'store.dart';

/// Pushes the scouting outbox to the server. Every upload uses a device-generated id and the
/// server treats repeats as no-ops, so a sync interrupted at any point is simply run again.
class SyncService extends ChangeNotifier {
  SyncService(this._store, this._api);

  final LocalStore _store;
  final ApiClient _api;
  Timer? _timer;
  Future<void>? _running;

  int pending = 0;
  bool syncing = false;
  String? lastError;
  DateTime? lastSuccess;
  bool authExpired = false;

  void startPeriodic([Duration every = const Duration(minutes: 1)]) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => syncNow());
    syncNow();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> refreshPending() async {
    pending = await _store.pendingCount();
    notifyListeners();
  }

  /// Runs one sync pass; concurrent callers share the pass already in flight.
  Future<void> syncNow() => _running ??= _sync().whenComplete(() => _running = null);

  Future<void> _sync() async {
    await refreshPending();
    if (pending == 0 || authExpired) return;
    syncing = true;
    notifyListeners();
    try {
      for (final note in await _store.unsyncedNotes()) {
        try {
          await _api.putNote(note);
          await _store.markNoteSynced(note.id);
        } on ApiException catch (e) {
          if (!e.isPermanent) rethrow;
          await _store.markNoteError(note.id, e.message); // keep it, surface it, carry on with the rest
        }
      }
      for (final photo in await _store.unsyncedPhotos()) {
        final file = File(photo.path);
        if (!await file.exists()) {
          await _store.markPhotoSynced(photo.id); // deleted on device: nothing left to send
          continue;
        }
        await _api.putPhoto(photo.noteId, photo.id, file);
        await _store.markPhotoSynced(photo.id);
      }
      lastError = null;
      lastSuccess = DateTime.now();
    } on AuthExpired catch (e) {
      authExpired = true;
      lastError = e.message;
    } on ApiException catch (e) {
      lastError = e.message;
    } on Exception {
      lastError = 'Offline. Will retry automatically.';
    } finally {
      syncing = false;
      await refreshPending();
    }
  }
}
